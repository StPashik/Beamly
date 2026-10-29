import Combine
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$automaticallyChecksForUpdates)
        // Sparkle permits an extra launch check immediately after startup, respecting its saved opt-out.
        if updater.canCheckForUpdates, updater.automaticallyChecksForUpdates {
            updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard controller.updater.automaticallyChecksForUpdates != enabled else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}
