import Darwin
import Foundation

/// Shared with the CLI runtime. The child inherits this open-file description
/// as stdin, so the lock survives launcher termination until the engine exits.
final class PortalSaveWriterLease {
    static let name = ".portal2-save-writer.lock"
    static let inheritedEnvironment = "P2_SAVE_WRITER_LEASE_STDIN"
    let handle: FileHandle

    init(userDirectory: URL) throws {
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let location = userDirectory.appendingPathComponent(Self.name)
        var descriptor = location.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        if descriptor < 3 {
            let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, Int32(3))
            let error = currentPOSIXError()
            _ = close(descriptor)
            guard duplicate >= 0 else { throw error }
            descriptor = duplicate
        }
        var properties = stat()
        guard fstat(descriptor, &properties) == 0,
              properties.st_mode & S_IFMT == S_IFREG,
              properties.st_nlink == 1,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(descriptor)
            throw LeaseError.busy
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private enum LeaseError: LocalizedError {
        case busy
        var errorDescription: String? { "Another Portal 2 process may be using these saves. Close it and try again." }
    }
}

private func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
