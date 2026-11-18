import Combine
import CryptoKit
import Darwin
import Foundation

public enum SnapshotSaveLayout: Sendable {
    /// One directory of coupled files, such as a campaign save profile.
    case directory(id: String)
    /// Direct children containing level.dat are independent Minecraft worlds.
    case worldDirectories
}

public struct SnapshotSaveChoice: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
}

public struct SnapshotSaveConflict: Identifiable, Sendable, Equatable {
    public var id: String { unit }
    public let unit: String
    public let choices: [SnapshotSaveChoice]
}

enum SnapshotSaveError: LocalizedError {
    case stale, busy, accountChanged, pending, invalid, missing, localChanged
    case io(String)

    var errorDescription: String? {
        switch self {
        case .stale: "The game is using this device's saves."
        case .busy: "iCloud is still finishing a previous check. Try Sync Now again."
        case .accountChanged: "The iCloud account changed. Sign back into the previous account to resume sync."
        case .pending: "Waiting for iCloud to deliver the save files. Try Sync Now again."
        case .invalid: "A save revision could not be verified. The working saves were protected."
        case .missing: "The selected save is no longer available. Refresh the iCloud saves list."
        case .localChanged: "A local folder changed during sync. Its contents were preserved."
        case .io(let message): message
        }
    }
}

/// Only local, constant-size metadata and the atomic directory promotion may hold this lock.
final class SnapshotSaveLease: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var open = true

    func token() -> UInt64? { lock.withLock { open ? epoch : nil } }
    func setIdle(_ idle: Bool) {
        lock.withLock {
            epoch &+= 1
            open = idle
        }
    }

    func validate(_ token: UInt64) throws {
        guard self.token() == token else { throw SnapshotSaveError.stale }
    }

    func commit<T>(_ token: UInt64, _ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard open, epoch == token else { throw SnapshotSaveError.stale }
            return try body()
        }
    }
}

/// The store and each mounted transport use immutable content-addressed objects. The local state
/// points at the last snapshot that represented the working tree. A reconnect adds descendants
/// or independent branches without rewriting another device's head.
final class SnapshotSaveStore: @unchecked Sendable {
    struct File: Codable, Equatable, Sendable {
        let path: String
        let bytes: Int64
        let hash: String
    }

    struct Body: Codable, Equatable, Sendable {
        let unit: String
        let parents: [String]
        let files: [File]
    }

    struct Revision: Codable, Sendable {
        let version: Int
        let id: String
        let body: Body
        let created: Date
    }

    struct Result: Sendable {
        let conflicts: [SnapshotSaveConflict]
        let pending: Bool
        let offline: Bool
    }

    struct Transport: Sendable {
        let root: URL
        let account: Data?
        let discover: (@Sendable (URL) throws -> [URL])?
        let receipt: @Sendable (URL) throws -> Bool
        let makeAvailable: @Sendable (URL) throws -> Void
        let authorize: @Sendable () throws -> Void

        init(root: URL, account: Data? = nil,
             discover: (@Sendable (URL) throws -> [URL])? = nil,
             receipt: @escaping @Sendable (URL) throws -> Bool = { _ in true },
             makeAvailable: @escaping @Sendable (URL) throws -> Void = { _ in },
             authorize: @escaping @Sendable () throws -> Void = {}) {
            self.root = root
            self.account = account
            self.discover = discover
            self.receipt = receipt
            self.makeAvailable = makeAvailable
            self.authorize = authorize
        }
    }

    private struct State: Codable {
        var working: [String: String] = [:]
        var outbox: Set<String> = []
        var account: Data?
    }

    private let liveRoot: URL
    private let root: URL
    private let layout: SnapshotSaveLayout
    let lease: SnapshotSaveLease
    private let runLock = NSLock()
    private var running = false
    private let files = FileManager.default
    private static let manifestLimit = 16 * 1024 * 1024

    init(liveRoot: URL, storeRoot: URL, layout: SnapshotSaveLayout, lease: SnapshotSaveLease) {
        self.liveRoot = liveRoot
        root = storeRoot
        self.layout = layout
        self.lease = lease
    }

    func sync(token: UInt64, mount: () throws -> Transport?,
              selected: (unit: String, revision: String)? = nil) throws -> Result {
        let admitted = runLock.withLock {
            guard !running else { return false }
            running = true
            return true
        }
        guard admitted else { throw SnapshotSaveError.busy }
        defer { runLock.withLock { running = false } }
        try lease.validate(token)
        try prepareLocalStore()
        let fd = open(root.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SnapshotSaveError.invalid }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw SnapshotSaveError.busy }

        var state = try loadState()
        var revisions = try loadRevisions(in: manifests(root))
        let authored = try loadRevisions(in: pendingRecords)
        revisions.merge(authored) { current, _ in current }
        state.outbox.formUnion(authored.keys)
        try capture(token: token, revisions: &revisions, state: &state)
        try lease.validate(token)

        let transport = try mount()
        var discoveryPending = false
        if let transport {
            try bind(transport, state: &state)
            let remote = try loadRemote(transport, token: token)
            revisions.merge(remote.revisions) { local, _ in local }
            discoveryPending = remote.pending
        }

        if let selected {
            guard !discoveryPending else { throw SnapshotSaveError.pending }
            guard let revision = revisions[selected.revision], revision.body.unit == selected.unit else {
                throw SnapshotSaveError.missing
            }
            let currentHeads = heads(for: selected.unit, in: revisions)
            guard currentHeads.count > 1, currentHeads.contains(where: { $0.id == revision.id }),
                  currentHeads.allSatisfy({ hasCompleteLineage($0, in: revisions) }) else {
                throw SnapshotSaveError.missing
            }
            try materialize(revision, transport: transport, token: token)
            let resolved = try Self.revision(unit: selected.unit, parents: currentHeads.map(\.id),
                                             files: revision.body.files)
            try install(resolved, token: token, state: &state, publish: true,
                        authorize: { try transport?.authorize() })
            revisions[resolved.id] = resolved
        }

        guard let transport else {
            return Result(conflicts: conflicts(in: revisions, working: state.working),
                          pending: !state.outbox.isEmpty, offline: true)
        }

        var hasPendingTransfer = try publishOutbox(state: &state, revisions: revisions,
                                                   transport: transport, token: token)
        if discoveryPending {
            return Result(conflicts: conflicts(in: revisions, working: state.working), pending: true, offline: false)
        }
        let units = Set(revisions.values.map { $0.body.unit })
        for unit in units.sorted() {
            try lease.validate(token)
            let tops = heads(for: unit, in: revisions)
            guard tops.allSatisfy({ hasCompleteLineage($0, in: revisions) }) else {
                hasPendingTransfer = true
                continue
            }
            if tops.count > 1 {
                // Retain both heads locally whenever all referenced content is available.
                for head in tops {
                    do { try materialize(head, transport: transport, token: token) }
                    catch SnapshotSaveError.pending { hasPendingTransfer = true }
                }
                continue
            }
            guard let head = tops.first, state.working[unit] != head.id else { continue }
            let existing = liveDirectory(for: unit)
            // A missing previously used unit is an explicit local absence. Never resurrect it
            // just because the provider still holds the old revision.
            if state.working[unit] != nil && !files.fileExists(atPath: existing.path) { continue }
            if let local = state.working[unit], !containsAncestor(local, of: head.id, revisions: revisions) {
                continue
            }
            do {
                try materialize(head, transport: transport, token: token)
                try install(head, token: token, state: &state, publish: false, authorize: transport.authorize)
            } catch SnapshotSaveError.pending {
                hasPendingTransfer = true
            } catch SnapshotSaveError.localChanged {
                hasPendingTransfer = true
            }
        }
        return Result(conflicts: conflicts(in: revisions, working: state.working), pending: hasPendingTransfer, offline: false)
    }

    private func prepareLocalStore() throws {
        let live = liveRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let store = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let count = min(live.count, store.count)
        guard !live.prefix(count).elementsEqual(store.prefix(count)), live.count > 1, store.count > 1 else {
            throw SnapshotSaveError.invalid
        }
        try files.createDirectory(at: objects(root), withIntermediateDirectories: true)
        try files.createDirectory(at: manifests(root), withIntermediateDirectories: true)
        try files.createDirectory(at: pendingRecords, withIntermediateDirectories: true)
    }

    private func capture(token: UInt64, revisions: inout [String: Revision], state: inout State) throws {
        for (unit, directory) in try localUnits() {
            try lease.validate(token)
            let entries = try snapshot(directory, skipWorldLock: layout.isWorlds, token: token)
            guard !entries.isEmpty else { continue }
            let previous = state.working[unit]
            if let previous, revisions[previous]?.body.files == entries { continue }
            // An atomic promotion can survive a crash before its small state file was updated.
            if let captured = heads(for: unit, in: revisions).first(where: { $0.body.files == entries }) {
                state.working[unit] = captured.id
                try lease.commit(token) { try writeState(state) }
                continue
            }
            let revision = try Self.revision(unit: unit, parents: previous.map { [$0] } ?? [], files: entries)
            try lease.validate(token)
            try storeRevision(revision, in: pendingRecords)
            try storeRevision(revision, at: root)
            state.working[unit] = revision.id
            state.outbox.insert(revision.id)
            try lease.commit(token) { try writeState(state) }
            revisions[revision.id] = revision
        }
    }

    private func localUnits() throws -> [(String, URL)] {
        guard files.fileExists(atPath: liveRoot.path) else { return [] }
        if case .directory(let id) = layout {
            guard Self.safeName(id), try directoryIsPlain(liveRoot) else { throw SnapshotSaveError.invalid }
            return [(id, liveRoot)]
        }
        guard try directoryIsPlain(liveRoot) else { throw SnapshotSaveError.invalid }
        let children = try files.contentsOfDirectory(at: liveRoot, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])
        return try children.compactMap { directory in
            let id = directory.lastPathComponent
            guard Self.safeName(id), try directoryIsPlain(directory),
                  files.fileExists(atPath: directory.appendingPathComponent("level.dat").path) else { return nil }
            return (id, directory)
        }.sorted { $0.0 < $1.0 }
    }

    private func snapshot(_ directory: URL, skipWorldLock: Bool, token: UInt64) throws -> [File] {
        var result: [File] = []
        func visit(_ parent: URL, relative: String, depth: Int) throws {
            guard depth < 48 else { throw SnapshotSaveError.invalid }
            try lease.validate(token)
            let urls = try files.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            for source in urls {
                let name = source.lastPathComponent
                if skipWorldLock && relative.isEmpty && name == "session.lock" { continue }
                guard Self.safeName(name) else { throw SnapshotSaveError.invalid }
                let path = relative.isEmpty ? name : relative + "/" + name
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey,
                                                                 .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw SnapshotSaveError.invalid }
                if values.isDirectory == true {
                    try visit(source, relative: path, depth: depth + 1)
                } else {
                    guard values.isRegularFile == true else { throw SnapshotSaveError.invalid }
                    let digest = try fingerprint(source) { try self.lease.validate(token) }
                    let object = objects(root).appendingPathComponent(digest.hash)
                    if !files.fileExists(atPath: object.path) {
                        try copyVerified(from: source, to: object, hash: digest.hash, bytes: digest.bytes) {
                            try self.lease.validate(token)
                        }
                    }
                    result.append(File(path: path, bytes: digest.bytes, hash: digest.hash))
                }
            }
        }
        try visit(directory, relative: "", depth: 0)
        return result.sorted { $0.path < $1.path }
    }

    private func publishOutbox(state: inout State, revisions: [String: Revision], transport: Transport,
                               token: UInt64) throws -> Bool {
        guard !state.outbox.isEmpty else { return false }
        try transport.authorize()
        try files.createDirectory(at: objects(transport.root), withIntermediateDirectories: true)
        try files.createDirectory(at: manifests(transport.root), withIntermediateDirectories: true)
        var ordered: [String] = []
        var visited = Set<String>()
        func visit(_ id: String) {
            guard state.outbox.contains(id), visited.insert(id).inserted else { return }
            for parent in revisions[id]?.body.parents ?? [] { visit(parent) }
            ordered.append(id)
        }
        for id in state.outbox.sorted() { visit(id) }
        for id in ordered {
            guard let revision = revisions[id] else { throw SnapshotSaveError.invalid }
            guard revision.body.parents.allSatisfy({ !state.outbox.contains($0) }) else { continue }
            try lease.validate(token)
            var ready = true
            let unique = Dictionary(grouping: revision.body.files, by: \.hash).values.compactMap(\.first)
            for file in unique {
                try lease.validate(token)
                let destination = objects(transport.root).appendingPathComponent(file.hash)
                let source = objects(root).appendingPathComponent(file.hash)
                do {
                    try transfer(source, to: destination, object: file, transport: transport, token: token)
                    if try !transport.receipt(destination) { ready = false }
                } catch SnapshotSaveError.pending {
                    ready = false
                }
            }
            guard ready else { continue }
            let manifestURL = manifests(transport.root).appendingPathComponent(id + ".json")
            try transport.authorize()
            try lease.validate(token)
            if files.fileExists(atPath: manifestURL.path) || placeholderExists(for: manifestURL) {
                do { try transport.makeAvailable(manifestURL) }
                catch SnapshotSaveError.pending { continue }
                guard try coordinatedRead(manifestURL, transport: transport, readManifest).id == id else {
                    throw SnapshotSaveError.invalid
                }
            } else {
                try coordinatedWrite(in: manifests(transport.root), transport: transport) { resolved in
                    try self.lease.validate(token)
                    try transport.authorize()
                    try self.storeRevision(revision, in: resolved)
                }
            }
            if try transport.receipt(manifestURL) {
                state.outbox.remove(id)
                try writeState(state)
                let intent = pendingRecords.appendingPathComponent(id + ".json")
                if files.fileExists(atPath: intent.path) { try files.removeItem(at: intent) }
            }
        }
        return !state.outbox.isEmpty
    }

    private func materialize(_ revision: Revision, transport: Transport?, token: UInt64) throws {
        for file in Dictionary(grouping: revision.body.files, by: \.hash).values.compactMap(\.first) {
            try lease.validate(token)
            let destination = objects(root).appendingPathComponent(file.hash)
            if files.fileExists(atPath: destination.path) {
                let identity = try fingerprint(destination) { try self.lease.validate(token) }
                guard identity.hash == file.hash, identity.bytes == file.bytes else { throw SnapshotSaveError.invalid }
                continue
            }
            guard let transport else { throw SnapshotSaveError.pending }
            let source = objects(transport.root).appendingPathComponent(file.hash)
            try transport.authorize()
            try transport.makeAvailable(source)
            guard files.fileExists(atPath: source.path) else { throw SnapshotSaveError.pending }
            try coordinatedRead(source, transport: transport) { resolved in
                try self.copyVerified(from: resolved, to: destination, hash: file.hash, bytes: file.bytes) {
                    try self.lease.validate(token)
                }
            }
        }
    }

    private func transfer(_ source: URL, to destination: URL, object: File, transport: Transport,
                          token: UInt64) throws {
        try transport.authorize()
        if files.fileExists(atPath: destination.path) || placeholderExists(for: destination) {
            try transport.makeAvailable(destination)
            let identity = try coordinatedRead(destination, transport: transport) { resolved in
                try self.fingerprint(resolved) { try self.lease.validate(token) }
            }
            guard identity.hash == object.hash, identity.bytes == object.bytes else { throw SnapshotSaveError.invalid }
        } else {
            try coordinatedWrite(in: destination.deletingLastPathComponent(), transport: transport) { directory in
                try transport.authorize()
                let file = directory.appendingPathComponent(destination.lastPathComponent)
                try self.copyVerified(from: source, to: file, hash: object.hash, bytes: object.bytes) {
                    try self.lease.validate(token)
                }
            }
        }
    }

    private func coordinatedRead<T>(_ url: URL, transport: Transport, _ body: (URL) throws -> T) throws -> T {
        guard transport.account != nil else { return try body(url) }
        var coordinationError: NSError?
        var result: Swift.Result<T, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            resolved in result = Swift.Result { try body(resolved) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw SnapshotSaveError.pending }
        return try result.get()
    }

    private func coordinatedWrite(in directory: URL, transport: Transport, _ body: (URL) throws -> Void) throws {
        guard transport.account != nil else { try body(directory); return }
        var coordinationError: NSError?
        var result: Swift.Result<Void, any Error>?
        NSFileCoordinator().coordinate(writingItemAt: directory, options: [], error: &coordinationError) {
            resolved in result = Swift.Result { try body(resolved) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw SnapshotSaveError.pending }
        try result.get()
    }

    private func install(_ revision: Revision, token: UInt64, state: inout State,
                         publish: Bool, authorize: () throws -> Void) throws {
        let target = liveDirectory(for: revision.body.unit)
        if layout.isWorlds {
            if files.fileExists(atPath: liveRoot.path), !(try directoryIsPlain(liveRoot)) {
                throw SnapshotSaveError.invalid
            }
            let siblings = files.fileExists(atPath: liveRoot.path)
                ? try files.contentsOfDirectory(atPath: liveRoot.path).filter {
                    Self.fold($0) == Self.fold(revision.body.unit)
                }
                : []
            if siblings.contains(where: { $0 != revision.body.unit }) { throw SnapshotSaveError.invalid }
        }
        let parent = target.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".portforge-restore-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        for file in revision.body.files {
            try lease.validate(token)
            let source = objects(root).appendingPathComponent(file.hash)
            let destination = staging.appendingPathComponent(file.path)
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try copyVerified(from: source, to: destination, hash: file.hash, bytes: file.bytes) {
                try self.lease.validate(token)
            }
        }
        // A Files import or another launcher may have edited the local tree while iCloud was
        // working. Detect that before promotion and give the new local bytes their own revision.
        if files.fileExists(atPath: target.path) {
            guard try directoryIsPlain(target) else { throw SnapshotSaveError.invalid }
            let current = try snapshot(target, skipWorldLock: layout.isWorlds, token: token)
            let expected = try state.working[revision.body.unit].map {
                try readManifest(manifests(root).appendingPathComponent($0 + ".json")).body.files
            } ?? []
            guard current == expected else { throw SnapshotSaveError.localChanged }
        } else if state.working[revision.body.unit] != nil {
            throw SnapshotSaveError.localChanged
        }
        try authorize()
        try lease.validate(token)
        if publish { try storeRevision(revision, in: pendingRecords) }
        try storeRevision(revision, at: root)
        try lease.commit(token) {
            if publish { state.outbox.insert(revision.id) }
            if files.fileExists(atPath: target.path) {
                guard try directoryIsPlain(target) else { throw SnapshotSaveError.invalid }
                let result = renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, target.path, UInt32(RENAME_SWAP))
                guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            } else {
                try files.moveItem(at: staging, to: target)
            }
            state.working[revision.body.unit] = revision.id
            try writeState(state)
        }
    }

    private func loadRemote(_ transport: Transport, token: UInt64) throws
        -> (revisions: [String: Revision], pending: Bool) {
        let directory = manifests(transport.root)
        let urls: [URL]
        if let discover = transport.discover {
            urls = try discover(directory)
        } else if files.fileExists(atPath: directory.path) {
            urls = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } else {
            urls = []
        }
        var revisions: [String: Revision] = [:]
        var pending = false
        for url in urls {
            try lease.validate(token)
            guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else { continue }
            let manifestURL: URL
            if url.lastPathComponent.hasPrefix("."), url.pathExtension == "icloud" {
                manifestURL = directory.appendingPathComponent(String(url.deletingPathExtension().lastPathComponent.dropFirst()))
            } else {
                manifestURL = url
            }
            guard manifestURL.pathExtension == "json",
                  Self.isHash(manifestURL.deletingPathExtension().lastPathComponent) else { continue }
            try transport.authorize()
            let revision: Revision
            do {
                try transport.makeAvailable(manifestURL)
                revision = try coordinatedRead(manifestURL, transport: transport, readManifest)
            } catch SnapshotSaveError.pending {
                pending = true
                continue
            } catch SnapshotSaveError.invalid {
                pending = true
                continue
            } catch is DecodingError {
                pending = true
                continue
            }
            try storeRevision(revision, at: root)
            revisions[revision.id] = revision
        }
        return (revisions, pending)
    }

    private func loadRevisions(in directory: URL) throws -> [String: Revision] {
        let urls = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles])
        var result: [String: Revision] = [:]
        for url in urls where url.pathExtension == "json" {
            let revision = try readManifest(url)
            result[revision.id] = revision
        }
        return result
    }

    private func readManifest(_ url: URL) throws -> Revision {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= Self.manifestLimit else { throw SnapshotSaveError.invalid }
        let revision = try JSONDecoder().decode(Revision.self, from: Data(contentsOf: url))
        let observed = try Self.revision(unit: revision.body.unit, parents: revision.body.parents,
                                         files: revision.body.files, date: revision.created)
        guard revision.version == 1, revision.id == observed.id, revision.body == observed.body,
              revision.id + ".json" == url.lastPathComponent, allow(unit: revision.body.unit) else {
            throw SnapshotSaveError.invalid
        }
        return revision
    }

    private static func revision(unit: String, parents: [String], files: [File], date: Date = Date()) throws -> Revision {
        guard safeName(unit), !files.isEmpty, parents.count <= 512, parents.allSatisfy(isHash),
              files.count <= 50_000,
              Set(files.map { fold($0.path) }).count == files.count,
              files.allSatisfy({ file in
                  file.bytes >= 0 && isHash(file.hash) && file.path.utf8.count < 3072 &&
                      file.path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                          safeName(String($0))
                      }
              }) else {
            throw SnapshotSaveError.invalid
        }
        let body = Body(unit: unit, parents: Array(Set(parents)).sorted(), files: files.sorted { $0.path < $1.path })
        let id = hex(SHA256.hash(data: try encode(body)))
        return Revision(version: 1, id: id, body: body, created: date)
    }

    private func heads(for unit: String, in revisions: [String: Revision]) -> [Revision] {
        let graph = revisions.values.filter { $0.body.unit == unit }
        let parents = Set(graph.flatMap { $0.body.parents })
        return graph.filter { !parents.contains($0.id) }.sorted { $0.id < $1.id }
    }

    private func containsAncestor(_ id: String, of descendant: String, revisions: [String: Revision]) -> Bool {
        var queue = [descendant]
        var visited = Set<String>()
        while let current = queue.popLast(), visited.insert(current).inserted {
            if current == id { return true }
            if let found = revisions[current] { queue.append(contentsOf: found.body.parents) }
            while let next = queue.last, visited.contains(next) { queue.removeLast() }
        }
        return false
    }

    private func hasCompleteLineage(_ revision: Revision, in revisions: [String: Revision]) -> Bool {
        var remaining = revision.body.parents
        var visited = Set<String>()
        while let id = remaining.popLast() {
            guard visited.insert(id).inserted else { continue }
            guard let parent = revisions[id], parent.body.unit == revision.body.unit else { return false }
            remaining.append(contentsOf: parent.body.parents)
        }
        return true
    }

    private func conflicts(in revisions: [String: Revision], working: [String: String])
        -> [SnapshotSaveConflict] {
        Set(revisions.values.map { $0.body.unit }).sorted().compactMap { unit in
            let candidates = heads(for: unit, in: revisions)
            guard candidates.count > 1 else { return nil }
            return SnapshotSaveConflict(unit: unit, choices: candidates.map {
                let source = working[unit] == $0.id ? "This device" : "Other version"
                return SnapshotSaveChoice(id: $0.id, label: source + " · "
                    + $0.created.formatted(date: .abbreviated, time: .shortened) + " · " + $0.id.prefix(8))
            })
        }
    }

    private func bind(_ transport: Transport, state: inout State) throws {
        guard let account = transport.account else { return }
        if let existing = state.account {
            guard Self.sameAccount(account, existing) else { throw SnapshotSaveError.accountChanged }
        } else {
            state.account = account
            try writeState(state)
        }
    }

    static func sameAccount(_ a: Data, _ b: Data) -> Bool {
        if a == b { return true }
        func decode(_ data: Data) -> NSObject? {
            guard let decoder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
            decoder.requiresSecureCoding = false
            defer { decoder.finishDecoding() }
            return decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSObject
        }
        guard let lhs = decode(a), let rhs = decode(b) else { return false }
        return lhs.isEqual(rhs)
    }

    private func loadState() throws -> State {
        let url = root.appendingPathComponent("state.json")
        guard files.fileExists(atPath: url.path) else { return State() }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
    }

    private func writeState(_ state: State) throws {
        try Self.encode(state).write(to: root.appendingPathComponent("state.json"), options: .atomic)
    }

    private func storeRevision(_ revision: Revision, at store: URL) throws {
        try storeRevision(revision, in: manifests(store))
    }

    private func storeRevision(_ revision: Revision, in directory: URL) throws {
        let url = directory.appendingPathComponent(revision.id + ".json")
        if files.fileExists(atPath: url.path) { return }
        let data = try Self.encode(revision)
        guard data.count <= Self.manifestLimit else { throw SnapshotSaveError.invalid }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".revision-" + UUID().uuidString)
        defer { try? files.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        do {
            try files.moveItem(at: temporary, to: url)
        } catch {
            guard files.fileExists(atPath: url.path), try readManifest(url).id == revision.id else { throw error }
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func fingerprint(_ url: URL, checking: () throws -> Void) throws -> (hash: String, bytes: Int64) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SnapshotSaveError.invalid }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var sha = SHA256()
        var count: Int64 = 0
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            try checking()
            sha.update(data: data)
            count += Int64(data.count)
        }
        return (Self.hex(sha.finalize()), count)
    }

    private func copyVerified(from source: URL, to target: URL, hash: String, bytes: Int64,
                              checking: () throws -> Void) throws {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".incoming-" + UUID().uuidString)
        defer { try? files.removeItem(at: temporary) }
        try checking()
        try files.copyItem(at: source, to: temporary)
        let actual = try fingerprint(temporary, checking: checking)
        guard actual.hash == hash, actual.bytes == bytes else { throw SnapshotSaveError.invalid }
        try checking()
        do {
            try files.moveItem(at: temporary, to: target)
        } catch {
            // Another replica may have added the same content-addressed object.
            guard files.fileExists(atPath: target.path) else { throw error }
            let existing = try fingerprint(target, checking: checking)
            guard existing.hash == hash, existing.bytes == bytes else { throw SnapshotSaveError.invalid }
        }
    }

    private func liveDirectory(for unit: String) -> URL {
        layout.isWorlds ? liveRoot.appendingPathComponent(unit, isDirectory: true) : liveRoot
    }
    private func allow(unit: String) -> Bool {
        if case .directory(let id) = layout { return id == unit }
        return Self.safeName(unit)
    }
    private func directoryIsPlain(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isDirectory == true && values.isSymbolicLink != true
    }
    private var pendingRecords: URL { root.appendingPathComponent("pending", isDirectory: true) }
    private func objects(_ at: URL) -> URL { at.appendingPathComponent("objects", isDirectory: true) }
    private func manifests(_ at: URL) -> URL { at.appendingPathComponent("revisions", isDirectory: true) }
    private func placeholderExists(for url: URL) -> Bool {
        files.fileExists(atPath: url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent + ".icloud").path)
    }

    static func safeName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 255 &&
            !value.contains("/") && !value.contains("\\") && !value.contains(":") &&
            value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func fold(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
    }
    private static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func hex<T: Sequence>(_ bytes: T) -> String where T.Element == UInt8 {
        let alphabet = Array("0123456789abcdef".utf8)
        return String(decoding: bytes.flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 15)]] }, as: UTF8.self)
    }
}

private extension SnapshotSaveLayout {
    var isWorlds: Bool {
        if case .worldDirectories = self { return true }
        return false
    }
}

/// Native launchers keep one controller per enabled save namespace. They call prepareForPlay or
/// playOffline before handing the directory to the engine, and report gameplayDidEnd after the
/// native writers have stopped. Recreating this object does not stop a running writer.
@MainActor
public final class SnapshotSaveController: ObservableObject {
    @Published public private(set) var status: String
    @Published public private(set) var isSyncing = false
    @Published public private(set) var conflicts: [SnapshotSaveConflict] = []
    @Published public var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: preference)
            if isEnabled {
                status = "Ready to check iCloud saves."
            } else {
                if playWaiter != nil { playOffline() }
                else if !isPlaying { lease.setIdle(true) }
                abandonStatus()
                status = "iCloud saves are off. Using this device's saves."
            }
        }
    }

    public let supportsICloud: Bool
    private let lease: SnapshotSaveLease
    private let store: SnapshotSaveStore
    private let mount: @Sendable () throws -> SnapshotSaveStore.Transport?
    private let preference: String
    private let deadline: Duration
    private var isPlaying = false
    private var invalidated = false
    private var nextPlayRequest: UInt64 = 0
    private var generation: UInt64 = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var playWaiter: CheckedContinuation<Bool, Never>?
    private var timer: Task<Void, Never>?

    public convenience init(liveRoot: URL, storeRoot: URL, layout: SnapshotSaveLayout,
                            containerIdentifier: String?, namespace: String) {
        self.init(liveRoot: liveRoot, storeRoot: storeRoot, layout: layout, namespace: namespace,
                  supportsICloud: containerIdentifier != nil) {
            guard let containerIdentifier else { return nil }
            return try Self.mountCloud(containerIdentifier, namespace: namespace)
        }
    }

    init(liveRoot: URL, storeRoot: URL, layout: SnapshotSaveLayout, namespace: String,
         supportsICloud: Bool, deadline: Duration = .seconds(8),
         mount: @escaping @Sendable () throws -> SnapshotSaveStore.Transport?) {
        let lease = SnapshotSaveLease()
        self.lease = lease
        store = SnapshotSaveStore(liveRoot: liveRoot, storeRoot: storeRoot, layout: layout, lease: lease)
        self.supportsICloud = supportsICloud
        self.deadline = deadline
        self.mount = mount
        preference = "PortForge.snapshot-sync." + namespace
        isEnabled = supportsICloud && (UserDefaults.standard.object(forKey: preference) as? Bool ?? true)
        status = supportsICloud ? "Ready to check iCloud saves." : "Saves stay on this device."
    }

    @discardableResult
    public func prepareForPlay() async -> Bool {
        guard !invalidated, !isPlaying, playWaiter == nil, !Task.isCancelled else { return false }
        guard isEnabled else { return playOffline() }
        nextPlayRequest &+= 1
        let request = nextPlayRequest
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    playWaiter = continuation
                    let limit = deadline
                    timer = Task { [weak self] in
                        do { try await Task.sleep(for: limit) } catch { return }
                        guard let self, self.nextPlayRequest == request, self.playWaiter != nil else { return }
                        self.playOffline()
                    }
                    if !isSyncing { startSync() }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.nextPlayRequest == request, let waiter = self.playWaiter else { return }
                self.playWaiter = nil
                self.timer?.cancel()
                self.timer = nil
                waiter.resume(returning: false)
            }
        }
    }

    /// Tap Play Offline during a check or call before a direct native launch route.
    @discardableResult
    public func playOffline() -> Bool {
        // A Play Offline action and its preflight can race; both request the same runtime lease.
        guard !invalidated, !isPlaying else { return false }
        isPlaying = true
        lease.setIdle(false)
        let waiter = playWaiter
        playWaiter = nil
        if isSyncing {
            abandonStatus()
            status = "Playing from this device's saves. Check iCloud again after quitting."
        }
        waiter?.resume(returning: true)
        return true
    }

    /// Retires this namespace before the launcher changes its local save root or profile.
    public func invalidate() {
        invalidated = true
        lease.setIdle(false)
        let waiter = playWaiter
        playWaiter = nil
        abandonStatus()
        waiter?.resume(returning: false)
    }

    public func gameplayDidEnd() {
        guard !invalidated, isPlaying else { return }
        isPlaying = false
        lease.setIdle(true)
    }

    public func syncNow() async {
        guard !invalidated else { return }
        guard !isPlaying else {
            status = "Quit the game before backing up saves."
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if !isSyncing { startSync() }
        }
    }

    /// Releases the idle UI immediately even if an outstanding provider call cannot be cancelled.
    /// That operation cannot subsequently promote a snapshot into the live directory.
    public func cancelSync() {
        guard !invalidated, !isPlaying, isSyncing, playWaiter == nil else { return }
        lease.setIdle(true)
        abandonStatus()
        status = "Save sync cancelled. Your working saves are on this device."
    }

    public func resolve(unit: String, keeping revisionID: String) async {
        guard !invalidated, isEnabled, !isPlaying, !isSyncing else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            startSync(selected: (unit, revisionID))
        }
    }

    private func startSync(selected: (String, String)? = nil) {
        guard !isPlaying, !isSyncing, let token = lease.token() else { return }
        generation &+= 1
        let run = generation
        isSyncing = true
        status = isEnabled ? "Checking iCloud saves…" : "Backing up this device's saves…"
        let store = self.store
        let mount: @Sendable () throws -> SnapshotSaveStore.Transport? = isEnabled ? self.mount : { @Sendable in nil }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = Result { try store.sync(token: token, mount: mount, selected: selected) }
            Task { @MainActor [weak self] in self?.complete(run, outcome: outcome) }
        }
    }

    private func complete(_ run: UInt64, outcome: Result<SnapshotSaveStore.Result, any Error>) {
        guard run == generation else { return }
        switch outcome {
        case .success(let report):
            conflicts = report.conflicts
            if report.offline {
                status = isEnabled ? "iCloud unavailable. Saved on this device." : "Local backup ready."
            } else if !report.conflicts.isEmpty {
                status = "Different saves are preserved. Choose a version before it becomes active."
            } else if report.pending {
                status = "Waiting for iCloud to deliver the save. Use Sync Now to check again."
            } else {
                status = "iCloud saves are up to date."
            }
        case .failure(let error):
            status = error.localizedDescription
        }
        abandonStatus()
        if playWaiter != nil { playOffline() }
    }

    private func abandonStatus() {
        generation &+= 1
        timer?.cancel()
        timer = nil
        isSyncing = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    private nonisolated static func mountCloud(_ identifier: String, namespace: String)
        throws -> SnapshotSaveStore.Transport? {
        guard identifier.hasPrefix("iCloud."), SnapshotSaveStore.safeName(namespace),
              let account = identity(),
              let container = FileManager.default.url(forUbiquityContainerIdentifier: identifier) else { return nil }
        @Sendable func authorize(_ original: Data) throws {
            guard let current = identity(), SnapshotSaveStore.sameAccount(original, current) else {
                throw SnapshotSaveError.accountChanged
            }
        }
        try authorize(account)
        let directory = container.appendingPathComponent("Documents/PortForgeSnapshots", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
        return SnapshotSaveStore.Transport(root: directory, account: account,
            discover: { try SnapshotMetadataGather(root: $0).collect() },
            receipt: { url in
                var fresh = url
                fresh.removeAllCachedResourceValues()
                let values = try fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
                                                               .ubiquitousItemUploadingErrorKey])
                if let error = values.ubiquitousItemUploadingError { throw error }
                return values.isUbiquitousItem == true && values.ubiquitousItemIsUploaded == true
            },
            makeAvailable: { url in
                var fresh = url
                fresh.removeAllCachedResourceValues()
                let values = try? fresh.resourceValues(forKeys: [.isUbiquitousItemKey,
                    .ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey])
                if let error = values?.ubiquitousItemDownloadingError { throw error }
                if values == nil || (values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus != .current) {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: fresh)
                    throw SnapshotSaveError.pending
                }
            },
            authorize: { try authorize(account) })
    }

    private nonisolated static func identity() -> Data? {
        guard let token = FileManager.default.ubiquityIdentityToken else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false)
    }
}

/// NSMetadataQuery owns its calls on a dedicated operation queue. Its synchronous waiter is on
/// the store's background thread and has a deadline even if start/stop never return.
private final class SnapshotMetadataGather: @unchecked Sendable {
    private let root: URL
    private let query = NSMetadataQuery()
    private let queue = OperationQueue()
    private let resultLock = NSLock()
    private var result: [URL]?
    private let gathered = DispatchSemaphore(value: 0)

    init(root: URL) {
        self.root = root
        queue.maxConcurrentOperationCount = 1
        query.operationQueue = queue
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, root.path + "/")
    }

    func collect() throws -> [URL] {
        let center = NotificationCenter.default
        let observer = center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query,
                                          queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.addOperation { self.readResults() }
        }
        defer {
            center.removeObserver(observer)
            queue.addOperation { self.query.stop() }
        }
        queue.addOperation { if !self.query.start() { self.gathered.signal() } }
        guard gathered.wait(timeout: .now() + .seconds(4)) == .success,
              let result = resultLock.withLock({ result }) else { throw SnapshotSaveError.pending }
        return result
    }

    private func readResults() {
        query.disableUpdates()
        let urls = query.results.compactMap { item -> URL? in
            guard let metadata = item as? NSMetadataItem,
                  let url = metadata.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  url.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else {
                return nil
            }
            return url
        }
        resultLock.withLock { result = urls }
        gathered.signal()
    }
}
