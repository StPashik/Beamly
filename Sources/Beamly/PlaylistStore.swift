import BeamlyCore
import Foundation

struct PlaylistStore {
    private enum LoadError: LocalizedError {
        case backupFailed(Error)
        case damaged(URL)

        var errorDescription: String? {
            switch self {
            case .backupFailed(let error):
                String(format: NSLocalizedString("Could not back up the damaged queue: %@", comment: ""), error.localizedDescription)
            case .damaged(let backup):
                String(format: NSLocalizedString("The saved queue is damaged. A backup was kept at %@.", comment: ""), backup.path)
            }
        }
    }

    private let url: URL

    init(url: URL?) {
        // Keep the original location so renaming the app preserves the queue.
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Peamer/playlist.json")
    }

    func load() throws -> Playlist? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            var playlist = try JSONDecoder().decode(Playlist.self, from: Data(contentsOf: url))
            if playlist.history == nil {
                playlist.history = []
                for item in playlist.items { playlist.recordHistory(item) }
            }
            return playlist
        } catch {
            let backup = url.deletingPathExtension().appendingPathExtension("unreadable-\(UUID().uuidString).json")
            do { try FileManager.default.moveItem(at: url, to: backup) }
            catch { throw LoadError.backupFailed(error) }
            throw LoadError.damaged(backup)
        }
    }

    func save(_ playlist: Playlist) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // An interrupted write must leave the previous playlist intact.
        try JSONEncoder().encode(playlist).write(to: url, options: .atomic)
    }
}
