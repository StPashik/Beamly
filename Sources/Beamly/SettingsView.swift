import AppKit
import BeamlyCore
import SwiftUI

struct SettingsView: View {
    @AppStorage("autoPlay") private var autoPlay = true
    @AppStorage("directPlayback") private var directPlayback = true
    @AppStorage("hardwareEncoding") private var hardwareEncoding = true
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("toolsDirectory") private var toolsDirectory = ""

    private var tools: FFmpegTools { FFmpegTools(customDirectory: toolsDirectory.isEmpty ? nil : URL(fileURLWithPath: toolsDirectory)) }

    var body: some View {
        Form {
            Section("Воспроизведение") {
                Toggle("Запускать добавленное видео автоматически", isOn: $autoPlay)
                Toggle("Прямое воспроизведение MP4 и MOV", isOn: $directPlayback)
                Text("Для совместимого видео перекодирование не требуется. Внешние субтитры включают обработку FFmpeg автоматически.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Аппаратное кодирование VideoToolbox", isOn: $hardwareEncoding)
                Text("Остальные форматы передаются как H.264/AAC до 1080p. При ошибке аппаратного кодирования используется программное.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Оформление") {
                Picker("Тема", selection: $appearance) {
                    Text("Системная").tag("system")
                    Text("Светлая").tag("light")
                    Text("Тёмная").tag("dark")
                }.pickerStyle(.segmented)
            }
            Section("FFmpeg") {
                LabeledContent("ffmpeg") { Text(tools.ffmpegURL?.path ?? "Не найден").textSelection(.enabled) }
                LabeledContent("ffprobe") { Text(tools.ffprobeURL?.path ?? "Не найден").textSelection(.enabled) }
                HStack {
                    Button("Выбрать папку…", action: chooseTools)
                    if !toolsDirectory.isEmpty { Button("Автоматически") { toolsDirectory = "" } }
                }
                Text("Beamly находит FFmpeg в Homebrew или выбранной папке. Без него доступны совместимые MP4/MOV через AVFoundation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Подключение") {
                Text("Mac и телевизор должны быть в одной сети. Разрешите Beamly доступ к локальной сети и входящие подключения, затем выберите телевизор кнопкой AirPlay.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).frame(width: 520, height: 490)
    }

    private func chooseTools() {
        let panel = NSOpenPanel()
        panel.title = "Папка с ffmpeg и ffprobe"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url { toolsDirectory = url.path }
    }
}
