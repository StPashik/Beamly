import AppKit
import BeamlyCore
import SwiftUI

@main
struct BeamlyApp: App {
    @StateObject private var model: AppModel
    @StateObject private var updater: AppUpdater
    private let language: AppLanguage
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("appearance") private var appearance = "system"

    init() {
        language = AppLanguage.configureAtLaunch()
        _model = StateObject(wrappedValue: AppModel())
        _updater = StateObject(wrappedValue: AppUpdater())
    }

    var body: some Scene {
        Window("Beamly", id: "main") {
            ContentView(model: model)
                .environment(\.locale, Locale(identifier: language.rawValue))
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .onAppear { delegate.attach(model) }
        }
        .defaultSize(width: 674, height: 390)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Videos…", action: model.openFiles).keyboardShortcut("o")
                Button("Add Subtitles…", action: model.chooseSubtitle).keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.current == nil)
            }
            CommandMenu("Playback") {
                Button(LocalizedStringKey(model.isPlaying ? "Pause" : "Play"), action: model.togglePlay).keyboardShortcut(.space, modifiers: [])
                Button("Stop", action: model.stop).keyboardShortcut(".")
                Divider()
                Button("Next video", action: model.next).keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous video", action: model.previous).keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Skip Forward 10 Seconds") { model.seek(model.position + 10) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("Skip Back 10 Seconds") { model.seek(model.position - 10) }.keyboardShortcut(.leftArrow, modifiers: [])
                ChapterMenu(model: model)
                SleepTimerMenu(model: model)
                Divider()
                Toggle("Shuffle", isOn: Binding(get: { model.playlist.shuffle }, set: { _ in model.toggleShuffle() }))
                Picker("Repeat", selection: Binding(get: { model.playlist.repeatMode }, set: model.setRepeat)) {
                    Text("Off").tag(BeamlyCore.RepeatMode.off)
                    Text("One video").tag(BeamlyCore.RepeatMode.one)
                    Text("Entire queue").tag(BeamlyCore.RepeatMode.all)
                }
            }
        }
        Settings { SettingsView(updater: updater).environment(\.locale, Locale(identifier: language.rawValue)).preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private var pending: [URL] = []

    func attach(_ model: AppModel) {
        self.model = model
        if !pending.isEmpty { model.add(pending); pending.removeAll() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { model.add(urls) } else { pending += urls }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}
