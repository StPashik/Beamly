import Foundation
import Darwin

enum MediaCache {
    private static let session = "\(getpid())-\(UUID().uuidString)"

    static func workspace() async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            let root = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Beamly-Media", isDirectory: true)
            let workspace = root.appendingPathComponent(session, isDirectory: true)
            let permissions: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
            try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: permissions)
            guard isDirectory(root) else { throw CocoaError(.fileWriteNoPermission) }
            if !isDirectory(workspace) {
                removeAbandoned(in: root)
                try files.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: permissions)
            }
            guard isDirectory(workspace) else { throw CocoaError(.fileWriteNoPermission) }
            return workspace
        }.value
    }

    static func removeAbandoned(in root: URL) {
        let files = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return }
        for entry in entries {
            let name = entry.lastPathComponent.split(separator: "-", maxSplits: 1)
            // A reused PID or an inaccessible process may still own an active buffer.
            guard name.count == 2, let pid = pid_t(name[0]), pid > 1, UUID(uuidString: String(name[1])) != nil,
                  isDirectory(entry), kill(pid, 0) == -1, errno == ESRCH else { continue }
            try? files.removeItem(at: entry)
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink == false
    }
}
