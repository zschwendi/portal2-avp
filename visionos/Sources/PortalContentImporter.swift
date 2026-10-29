#if P2_GAME
import Combine
import CryptoKit
import Foundation

// Developer bootstrap: imports owned Portal 2 content from tools/serve_owned_content.py over the LAN.
enum PortalContentImportError: LocalizedError {
    case badManifestURL, badManifest(String), unsafePath(String), http(Int), unexpectedResponse
    case sizeMismatch(String), hashMismatch(String)

    var errorDescription: String? {
        switch self {
        case .badManifestURL: return "The import address is not a valid content manifest address."
        case .badManifest(let why): return "The content manifest is invalid: \(why)."
        case .unsafePath(let path): return "Refusing unsafe content path \(path)."
        case .http(let code): return "The content server answered HTTP \(code)."
        case .unexpectedResponse: return "The content server sent an unexpected response."
        case .sizeMismatch(let path): return "Downloaded size does not match the manifest for \(path)."
        case .hashMismatch(let path): return "Downloaded SHA-256 does not match the manifest for \(path)."
        }
    }
}

struct PortalContentManifest: Decodable, Sendable {
    struct File: Decodable, Sendable {
        let id: Int
        let path: String
        let bytes: Int64
        let sha256: String
    }
    let version: Int
    let totalBytes: Int64
    let files: [File]

    enum CodingKeys: String, CodingKey { case version, files, totalBytes = "total_bytes" }
}

@MainActor
final class PortalContentImporter: ObservableObject {
    @Published var status = "Idle"
    @Published var completedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0

    nonisolated static let allowedGameDirs: Set<String> = ["bin", "platform", "update", "portal2", "portal2_dlc1", "portal2_dlc2"]
    nonisolated static let backupsFolder = "Portal2 Import Backups"
    nonisolated static let stagingFolder = "Portal2 Import Staging"
    private var backupRun: URL?
    private var runID = UUID()

    func run(manifestURL: URL, documents: URL) async throws {
        do {
            try await perform(manifestURL: manifestURL, documents: documents.standardizedFileURL)
        } catch is CancellationError {
            status = "Import cancelled; completed files were kept"
            throw CancellationError()
        } catch let error as URLError {
            status = "Import failed: network error (\(URLError.errorDomain) \(error.code.rawValue))"
            throw error
        } catch {
            status = "Import failed: \(error.localizedDescription)"
            throw error
        }
    }

    private func perform(manifestURL: URL, documents: URL) async throws {
        let base = try Self.capabilityBase(manifestURL)
        let fm = FileManager.default
        let documents = documents.resolvingSymlinksInPath()
        let realRoot = documents.resolvingSymlinksInPath().path
        let staging = documents.appendingPathComponent(Self.stagingFolder, isDirectory: true)
            .appendingPathComponent(UUID().uuidString,isDirectory: true)
        try Self.checkedDirectory(staging,documents: documents)
        let transfer = PortalTransfer(staging: staging,documents: documents)
        defer { transfer.invalidate(); Self.removeStaged(staging,documents: documents) }
        runID = UUID()
        let generation = runID
        backupRun = nil
        completedBytes = 0
        totalBytes = 0

        status = "Fetching manifest"
        let manifestFile = try await fetch(transfer, try Self.url(base, "manifest.json"), label: "manifest") { _ in }
        defer { Self.removeStaged(manifestFile,documents: documents) }
        let manifestSize = (try fm.attributesOfItem(atPath: manifestFile.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard manifestSize <= 64 << 20 else { throw PortalContentImportError.badManifest("too large") }
        let manifest = try Self.validate(try Data(contentsOf: manifestFile))
        let plan = try manifest.files.map { ($0, try Self.destination(for: $0.path, in: documents, realRoot: realRoot)) }
        totalBytes = manifest.totalBytes

        var done: Int64 = 0, reused = 0, fetched = 0
        for (index, (file, dest)) in plan.enumerated() {
            try Task.checkCancellation()
            try Self.rejectLinks(dest,documents: documents)
            let label = "\(index + 1)/\(plan.count) \(file.path)"
            status = "Checking \(label)"
            if try await Self.matches(dest, file) {
                reused += 1
                done += file.bytes
                completedBytes = done
                continue
            }
            status = "Downloading \(label)"
            let start = done, bytes = file.bytes
            let staged = try await fetch(transfer, try Self.url(base, "file/\(file.id)"), label: label) { [weak self] written in
                Task { @MainActor in
                    guard let self, self.runID == generation else { return }
                    self.completedBytes = max(self.completedBytes, start + min(written, bytes))
                }
            }
            do {
                status = "Verifying \(label)"
                let size = (try fm.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?.int64Value
                guard size == file.bytes else { throw PortalContentImportError.sizeMismatch(file.path) }
                guard try await Self.sha256Hex(of: staged) == file.sha256.lowercased() else {
                    throw PortalContentImportError.hashMismatch(file.path)
                }
                try install(staged, at: dest, relativePath: file.path, documents: documents)
            } catch {
                Self.removeStaged(staged,documents: documents)
                throw error
            }
            fetched += 1
            done += file.bytes
            completedBytes = done
        }
        let size = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
        status = "Imported \(fetched) files, reused \(reused) (\(size))"
    }

    // Seconds before each retry: initial attempt plus three. Each retry restarts only the current file.
    nonisolated static let retryDelays: [UInt64] = [1, 2, 4]

    nonisolated static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost: return true
        default: return false
        }
    }

    // Retries only transient connection failures; HTTP, origin, size/hash and cancellation errors propagate unchanged.
    private func fetch(_ transfer: PortalTransfer, _ url: URL, label: String,
                       progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        for (attempt, delay) in Self.retryDelays.enumerated() {
            do {
                return try await transfer.download(url, progress: progress)
            } catch let error as URLError where Self.isTransient(error) {
                // Status carries only the error domain and code, never the URL or token.
                status = "Network interrupted (\(URLError.errorDomain) \(error.code.rawValue)); retrying \(label) in \(delay)s"
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                status = "Downloading \(label) (attempt \(attempt + 2)/\(Self.retryDelays.count + 1))"
            }
        }
        return try await transfer.download(url, progress: progress)
    }

    // Preserves any existing item under a unique backup path, then atomically renames the verified file in.
    private func install(_ staged: URL, at dest: URL, relativePath: String, documents: URL) throws {
        let fm = FileManager.default
        try Self.rejectLinks(dest,documents: documents)
        try Self.checkedDirectory(dest.deletingLastPathComponent(),documents: documents)
        try Self.rejectLinks(staged,documents: documents)
        if let attrs = try? fm.attributesOfItem(atPath: dest.path) {
            if backupRun == nil {
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                backupRun = documents.appendingPathComponent(Self.backupsFolder, isDirectory: true)
                    .appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
            }
            let backup = backupRun!.appendingPathComponent(relativePath)
            try Self.checkedDirectory(backup.deletingLastPathComponent(),documents: documents)
            if attrs[.type] as? FileAttributeType == .typeRegular {
                try fm.linkItem(at: dest, to: backup)
            } else {
                try fm.moveItem(at: dest, to: backup)
            }
        }
        try Self.rejectLinks(dest,documents: documents)
        guard rename(staged.path, dest.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    nonisolated static func rejectLinks(_ url: URL,documents: URL) throws {
        let root = documents.path, path = url.standardizedFileURL.path
        guard path == root || path.hasPrefix(root+"/") else { throw PortalContentImportError.unsafePath("outside Documents") }
        var current = documents
        for component in path.dropFirst(root.count).split(separator: "/") {
            current.appendPathComponent(String(component))
            var info = stat()
            if lstat(current.path,&info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                throw PortalContentImportError.unsafePath("symbolic link in import destination")
            }
        }
    }

    nonisolated static func checkedDirectory(_ url: URL,documents: URL) throws {
        try rejectLinks(url,documents: documents)
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true)
        try rejectLinks(url,documents: documents)
    }

    nonisolated static func removeStaged(_ url: URL,documents: URL) {
        guard (try? rejectLinks(url,documents: documents)) != nil else { return }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func capabilityBase(_ manifestURL: URL) throws -> URLComponents {
        let suffix = "manifest.json"
        guard var parts = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.percentEncodedPath.hasSuffix("/" + suffix)
        else { throw PortalContentImportError.badManifestURL }
        parts.percentEncodedPath = String(parts.percentEncodedPath.dropLast(suffix.count))
        guard parts.percentEncodedPath.count > 2 else { throw PortalContentImportError.badManifestURL }
        return parts
    }

    nonisolated static func url(_ base: URLComponents, _ route: String) throws -> URL {
        var parts = base
        parts.percentEncodedPath += route
        guard let url = parts.url else { throw PortalContentImportError.badManifestURL }
        return url
    }

    nonisolated static func validate(_ data: Data) throws -> PortalContentManifest {
        let manifest: PortalContentManifest
        do { manifest = try JSONDecoder().decode(PortalContentManifest.self, from: data) } catch {
            throw PortalContentImportError.badManifest("unreadable JSON")
        }
        guard manifest.version == 1 else { throw PortalContentImportError.badManifest("unsupported version") }
        var ids = Set<Int>(), paths = Set<String>(), dirs = Set<String>()
        var sum: Int64 = 0
        let hex = Set("0123456789abcdef")
        for file in manifest.files {
            guard file.id > 0, ids.insert(file.id).inserted else { throw PortalContentImportError.badManifest("duplicate id") }
            try checkPath(file.path)
            guard paths.insert(file.path).inserted else { throw PortalContentImportError.badManifest("duplicate path") }
            let digest = file.sha256.lowercased()
            guard file.bytes >= 0, digest.count == 64, digest.allSatisfy(hex.contains) else {
                throw PortalContentImportError.badManifest("bad size or sha256 for \(file.path)")
            }
            let (next, overflow) = sum.addingReportingOverflow(file.bytes)
            guard !overflow else { throw PortalContentImportError.badManifest("size overflow") }
            sum = next
            let comps = file.path.split(separator: "/")
            for end in 1..<comps.count { dirs.insert(comps[..<end].joined(separator: "/")) }
        }
        guard sum == manifest.totalBytes else { throw PortalContentImportError.badManifest("total_bytes mismatch") }
        guard paths.isDisjoint(with: dirs) else { throw PortalContentImportError.badManifest("file/directory conflict") }
        guard Set(["prep/layout.json","linux/portal2_linux","game/portal2/pak01_dir.vpk"]).isSubset(of: paths) else {
            throw PortalContentImportError.badManifest("required Portal 2 files are missing")
        }
        return manifest
    }

    nonisolated static func checkPath(_ path: String) throws {
        let comps = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              comps.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw PortalContentImportError.unsafePath(path) }
        let allowed = (comps.count >= 2 && (comps[0] == "prep" || comps[0] == "linux"))
            || (comps.count >= 3 && comps[0] == "game" && allowedGameDirs.contains(comps[1]))
        guard allowed else { throw PortalContentImportError.unsafePath(path) }
    }

    // Rejects destinations whose existing components are symlinks resolving outside Documents.
    nonisolated static func destination(for path: String, in documents: URL, realRoot: String) throws -> URL {
        try checkPath(path)
        var url = documents
        for comp in path.split(separator: "/") {
            url.appendPathComponent(String(comp))
            let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            if type == .typeSymbolicLink, !url.resolvingSymlinksInPath().path.hasPrefix(realRoot + "/") {
                throw PortalContentImportError.unsafePath(path)
            }
        }
        try rejectLinks(url,documents: documents)
        return url
    }

    nonisolated static func matches(_ url: URL, _ file: PortalContentManifest.File) async throws -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.int64Value == file.bytes
        else { return false }
        return try await sha256Hex(of: url) == file.sha256.lowercased()
    }

    nonisolated static func sha256Hex(of url: URL) async throws -> String {
        let work = Task.detached(priority: .utility) { () throws -> String in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

// One ephemeral session; downloads go to disk via URLSessionDownloadTask and are moved into staging.
private final class PortalTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<URL, Error>
        let expected: URL
        let progress: @Sendable (Int64) -> Void
        var lastReport: TimeInterval = 0
        var result: Result<URL, Error>?
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private let staging: URL
    private let documents: URL
    private var session: URLSession!

    init(staging: URL,documents: URL) {
        self.staging = staging
        self.documents = documents
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 3600
        config.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func invalidate() { session.invalidateAndCancel() }

    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        try Task.checkCancellation()
        let task = session.downloadTask(with: URLRequest(url: url))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    pending[task.taskIdentifier] = Pending(continuation: continuation, expected: url, progress: progress)
                }
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    // Never follow redirects; the 3xx response then fails the status check.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        let report: (@Sendable (Int64) -> Void)? = lock.withLock {
            guard var entry = pending[downloadTask.taskIdentifier], now - entry.lastReport >= 0.1 else { return nil }
            entry.lastReport = now
            pending[downloadTask.taskIdentifier] = entry
            return entry.progress
        }
        report?(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        let expected = lock.withLock { pending[id]?.expected }
        let result: Result<URL, Error>
        if let http = downloadTask.response as? HTTPURLResponse, let expected,
           http.url?.absoluteString == expected.absoluteString {
            if http.statusCode == 200 {
                let dest = staging.appendingPathComponent(UUID().uuidString)
                result = Result {
                    try PortalContentImporter.rejectLinks(dest,documents: documents)
                    try FileManager.default.moveItem(at: location, to: dest)
                    return dest
                }
            } else {
                result = .failure(PortalContentImportError.http(http.statusCode))
            }
        } else {
            result = .failure(PortalContentImportError.unexpectedResponse)
        }
        lock.withLock { pending[id]?.result = result }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error {
            if case .success(let staged)? = entry.result { PortalContentImporter.removeStaged(staged,documents: documents) }
            let cancelled = (error as? URLError)?.code == .cancelled
            entry.continuation.resume(throwing: cancelled ? CancellationError() : error)
        } else {
            entry.continuation.resume(with: entry.result ?? .failure(PortalContentImportError.unexpectedResponse))
        }
    }
}
#endif
