import AppKit
import BeamlyCore
import SwiftUI

@main
struct BeamlyApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        Window("Beamly", id: "main") {
            ContentView(model: model)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .onAppear { delegate.attach(model) }
        }
        .defaultSize(width: 674, height: 390)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Добавить видео…", action: model.openFiles).keyboardShortcut("o")
                Button("Добавить субтитры…", action: model.chooseSubtitle).keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.current == nil)
            }
            CommandMenu("Воспроизведение") {
                Button(model.isPlaying ? "Пауза" : "Воспроизвести", action: model.togglePlay).keyboardShortcut(.space, modifiers: [])
                Button("Остановить", action: model.stop).keyboardShortcut(".")
                Divider()
                Button("Следующее видео", action: model.next).keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Предыдущее видео", action: model.previous).keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Вперёд на 10 секунд") { model.seek(model.position + 10) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("Назад на 10 секунд") { model.seek(model.position - 10) }.keyboardShortcut(.leftArrow, modifiers: [])
                Divider()
                Toggle("Перемешивать", isOn: Binding(get: { model.playlist.shuffle }, set: { _ in model.toggleShuffle() }))
                Picker("Повтор", selection: Binding(get: { model.playlist.repeatMode }, set: model.setRepeat)) {
                    Text("Выключен").tag(BeamlyCore.RepeatMode.off)
                    Text("Одно видео").tag(BeamlyCore.RepeatMode.one)
                    Text("Вся очередь").tag(BeamlyCore.RepeatMode.all)
                }
            }
        }
        Settings { SettingsView().preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil) }
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
