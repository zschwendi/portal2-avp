import Foundation

@main
struct PortalSaveChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portal-save-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try saveLayout(root)
        try saveGenerations(root, firstReconnect: "A")
        try saveGenerations(root, firstReconnect: "B")
        try writerOwnership(root)
        print("Portal 2 save adapter checks passed")
    }

    private static func saveLayout(_ root: URL) throws {
        let fm = FileManager.default
        let support = root.appendingPathComponent("Support")
        let user = root.appendingPathComponent("user-layout")
        let preserved = user.appendingPathComponent("portal2/SAVE")
        try fm.createDirectory(at: preserved, withIntermediateDirectories: true)
        let paths = try PortalSavePaths(userDirectory: user, supportDirectory: support)
        precondition(paths.liveRoot.lastPathComponent == "SAVE", "preserve the engine’s existing case")
        let separate = try PortalSavePaths(userDirectory: root.appendingPathComponent("fixture-override"),
                                           supportDirectory: support)
        precondition(!paths.storeRoot.path.hasPrefix(user.path + "/") && paths.storeRoot != separate.storeRoot)
        let linked = root.appendingPathComponent("linked-layout/portal2")
        try fm.createDirectory(at: linked, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linked.appendingPathComponent("save"), withDestinationURL: preserved)
        do {
            _ = try PortalSavePaths(userDirectory: linked.deletingLastPathComponent(), supportDirectory: support)
            fatalError("A linked save folder was accepted for replacement")
        } catch PortalSavePaths.LayoutError.unsupported {}
        print("PASS existing path casing, distinct local stores, and symlink protection")
    }

    private static func saveGenerations(_ root: URL, firstReconnect: String) throws {
        let testRoot = root.appendingPathComponent("order-" + firstReconnect)
        let support = testRoot.appendingPathComponent("support")
        let cloud = testRoot.appendingPathComponent("shared")
        let a = try PortalSavePaths(userDirectory: testRoot.appendingPathComponent("A"), supportDirectory: support)
        let b = try PortalSavePaths(userDirectory: testRoot.appendingPathComponent("B"), supportDirectory: support)
        let leaseA = SnapshotSaveLease()
        let leaseB = SnapshotSaveLease()
        let transport = SnapshotSaveStore.Transport(root: cloud)
        let layout = SnapshotSaveLayout.directory(id: PortalSavePaths.unit)

        func sync(_ paths: PortalSavePaths, _ lease: SnapshotSaveLease, online: Bool,
                  selected: (String, String)? = nil) throws -> SnapshotSaveStore.Result {
            // Reopening the local store on every pass also exercises its journal across restart.
            let store = SnapshotSaveStore(liveRoot: paths.liveRoot, storeRoot: paths.storeRoot,
                                          layout: layout, lease: lease)
            return try store.sync(token: lease.token()!, mount: { online ? transport : nil }, selected: selected)
        }
        func write(_ text: String, _ name: String, _ paths: PortalSavePaths) throws {
            let url = paths.liveRoot.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func read(_ name: String, _ paths: PortalSavePaths) -> String? {
            try? String(contentsOf: paths.liveRoot.appendingPathComponent(name), encoding: .utf8)
        }
        func assertGeneration(_ label: String, _ paths: PortalSavePaths) {
            precondition(read("quicksave.sav", paths) == label)
            precondition(read("quicksave.tga", paths) == label + "-thumbnail")
            precondition(read("world.hl1", paths) == label + "-level-state")
        }
        func update(_ label: String, _ paths: PortalSavePaths) throws {
            try write(label, "quicksave.sav", paths)
            try write(label + "-thumbnail", "quicksave.tga", paths)
            try write(label + "-level-state", "world.hl1", paths)
        }
        func revisionCount() throws -> Int {
            try FileManager.default.contentsOfDirectory(atPath: cloud.appendingPathComponent("revisions").path)
                .filter { $0.hasSuffix(".json") }.count
        }

        try update("baseline", a)
        _ = try sync(a, leaseA, online: true)
        _ = try sync(b, leaseB, online: true)
        assertGeneration("baseline", b)
        try update("A", a)
        try update("B", b)
        _ = try sync(a, leaseA, online: false)
        _ = try sync(b, leaseB, online: false)
        let initialCount = try revisionCount()
        precondition(initialCount == 1)
        let first = firstReconnect == "A" ? (a, leaseA) : (b, leaseB)
        let second = firstReconnect == "A" ? (b, leaseB) : (a, leaseA)
        _ = try sync(first.0, first.1, online: true)
        let conflict = try sync(second.0, second.1, online: true).conflicts.first!
        precondition(conflict.unit == PortalSavePaths.unit && conflict.choices.count == 2)
        assertGeneration("A", a)
        assertGeneration("B", b)
        let selected = (conflict.unit, conflict.choices[0].id)
        let resolved = try sync(second.0, second.1, online: true, selected: selected)
        precondition(resolved.conflicts.isEmpty)
        _ = try sync(first.0, first.1, online: true)
        let winner = read("quicksave.sav", a)!
        assertGeneration(winner, a)
        assertGeneration(winner, b)
        let revisions = try revisionCount()
        _ = try sync(a, leaseA, online: true)
        _ = try sync(b, leaseB, online: true)
        let repeatRevisions = try revisionCount()
        precondition(revisions == repeatRevisions)
        print("PASS Portal save, thumbnail and level files stay together for \(firstReconnect)-first reconnect")
    }

    private static func writerOwnership(_ root: URL) throws {
        let userDirectory = root.appendingPathComponent("writer")
        let lease = try PortalSaveWriterLease(userDirectory: userDirectory)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        child.standardInput = lease.handle
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        try lease.handle.close()
        do {
            _ = try PortalSaveWriterLease(userDirectory: userDirectory)
            fatalError("Another process acquired the tree while its game writer was alive")
        } catch {}
        child.terminate()
        child.waitUntilExit()
        _ = try PortalSaveWriterLease(userDirectory: userDirectory)
        print("PASS inherited Mac lease survives closing the launcher handle and releases on child exit")
    }
}
