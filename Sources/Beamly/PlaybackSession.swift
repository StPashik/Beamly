import AVFoundation
import BeamlyCore

@MainActor
final class PlaybackSession {
    private(set) var server = MediaHTTPServer()
    var job: HLSJob?
    private var previous: (item: AVPlayerItem, server: MediaHTTPServer, job: HLSJob?)?

    func cancel(player: AVPlayer, keepingItem: Bool) {
        if keepingItem, let item = player.currentItem {
            // Keep the old item and its URLs alive until replacement is ready so AVKit retains the route.
            if previous?.item !== item {
                releasePrevious()
                job?.cancelPendingPreparation()
                previous = (item, server, job)
            } else {
                job?.stop()
                server.stop()
            }
            server = MediaHTTPServer()
        } else {
            if player.currentItem != nil { player.replaceCurrentItem(with: nil) }
            job?.stop()
            server.revokeAll()
            releasePrevious()
        }
        job = nil
    }

    func releasePrevious() {
        previous?.job?.stop()
        previous?.server.stop()
        previous = nil
    }
}
