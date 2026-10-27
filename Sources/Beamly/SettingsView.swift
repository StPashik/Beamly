import AppKit
import BeamlyCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var updater: AppUpdater
    @AppStorage("autoPlay") private var autoPlay = true
    @AppStorage("directPlayback") private var directPlayback = true
    @AppStorage("hardwareEncoding") private var hardwareEncoding = true
    @AppStorage("appLanguage") private var appLanguage = "en"
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("toolsDirectory") private var toolsDirectory = ""

    private var tools: FFmpegTools { FFmpegTools(customDirectory: toolsDirectory.isEmpty ? nil : URL(fileURLWithPath: toolsDirectory)) }

    var body: some View {
        Form {
            Section("Playback") {
                Toggle("Play added videos automatically", isOn: $autoPlay)
                Toggle("Play MP4 and MOV directly", isOn: $directPlayback)
                Text("Compatible videos do not need transcoding. External subtitles automatically enable FFmpeg processing.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Use VideoToolbox hardware encoding", isOn: $hardwareEncoding)
                Text("Other formats stream as H.264/AAC at up to 1080p. Software encoding is used if hardware encoding fails.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Language") {
                Picker("Language", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.displayName).tag(language.rawValue)
                    }
                }
                Text("Restart Beamly to apply the language.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }.pickerStyle(.segmented)
            }
            Section("FFmpeg") {
                LabeledContent("ffmpeg") { Text(tools.ffmpegURL?.path ?? NSLocalizedString("Not found", comment: "")).textSelection(.enabled) }
                LabeledContent("ffprobe") { Text(tools.ffprobeURL?.path ?? NSLocalizedString("Not found", comment: "")).textSelection(.enabled) }
                HStack {
                    Button("Choose Folder…", action: chooseTools)
                    if !toolsDirectory.isEmpty { Button("Automatic") { toolsDirectory = "" } }
                }
                Text("Beamly finds FFmpeg in Homebrew or a selected folder. Without it, compatible MP4/MOV files play via AVFoundation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Connection") {
                Text("Your Mac and TV must be on the same network. Allow Beamly to access the local network and accept incoming connections, then choose your TV with the AirPlay button.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Updates") {
                LabeledContent("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                }
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
                Text("New versions are downloaded from GitHub and installed after your confirmation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).frame(width: 520, height: 650)
    }

    private func chooseTools() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Folder containing ffmpeg and ffprobe", comment: "")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url { toolsDirectory = url.path }
    }
}
