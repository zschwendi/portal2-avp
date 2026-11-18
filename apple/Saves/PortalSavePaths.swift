import CryptoKit
import Foundation

/// The translated Source engine writes into its existing user overlay.
/// Keep the entire SAVE directory together, including thumbnails and auxiliary files.
struct PortalSavePaths: Sendable {
    let liveRoot: URL
    let storeRoot: URL
    static let namespace = "Portal2"
    static let unit = "portal2-campaign"

    init(userDirectory: URL, supportDirectory: URL) throws {
        let user = userDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let game = try Self.directory(named: "portal2", beneath: user)
        liveRoot = try Self.directory(named: "save", beneath: game)
        let storageKey = SHA256.hash(data: Data(user.path.utf8)).map { String(format: "%02x", $0) }.joined()
        storeRoot = supportDirectory
            .appendingPathComponent("Portal2/SaveSync", isDirectory: true)
            .appendingPathComponent(storageKey, isDirectory: true)
    }

    static func configuredContainer(in bundle: Bundle = .main) -> String? {
        guard let identifier = bundle.object(forInfoDictionaryKey: "Portal2CloudContainer") as? String,
              identifier.hasPrefix("iCloud."), !identifier.contains("$(") else { return nil }
        return identifier
    }

    private static func directory(named name: String, beneath parent: URL) throws -> URL {
        let manager = FileManager.default
        let expected = parent.appendingPathComponent(name, isDirectory: true)
        guard manager.fileExists(atPath: parent.path) else { return expected }
        let entries = try manager.contentsOfDirectory(at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let matches = entries.filter { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
        guard matches.count <= 1 else { throw LayoutError.ambiguous(expected.path) }
        guard let directory = matches.first else { return expected }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LayoutError.unsupported(directory.path)
        }
        return directory
    }

    enum LayoutError: LocalizedError {
        case ambiguous(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .ambiguous: "More than one folder matches Portal 2’s save path."
            case .unsupported: "Portal 2’s save path contains a link or a file where a folder was expected."
            }
        }
    }
}
