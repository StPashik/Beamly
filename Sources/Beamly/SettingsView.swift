import AppKit
import BeamlyCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var updater: AppUpdater
    @AppStorage("autoPlay") private var autoPlay = true
    @AppStorage("directPlayback") private var directPlayback = true
    @AppStorage("hardwareEncoding") private var hardwareEncoding = true
    @AppStorage("preferredAudioLanguage") private var preferredAudioLanguage = "default"
    @AppStorage("preferredSubtitleLanguage") private var preferredSubtitleLanguage = "automatic"
    @Environment(\.locale) private var locale
    @AppStorage("appLanguage") private var appLanguage = "en"
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("toolsDirectory") private var toolsDirectory = ""

    private var tools: FFmpegTools { FFmpegTools(customDirectory: toolsDirectory.isEmpty ? nil : URL(fileURLWithPath: toolsDirectory)) }
    private var trackLanguages: [(code: String, name: String)] {
        MediaLanguages.codes.map { (code: $0, name: locale.localizedString(forLanguageCode: $0) ?? $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section("Playback") {
                Toggle("Play added videos automatically", isOn: $autoPlay)
                Toggle("Preserve video quality", isOn: $directPlayback)
                Text("Compatible MP4/MOV files play directly. HEVC/H.264 in MKV keeps its original resolution and HDR10/HLG. Text subtitles use a separate track; ASS styling is simplified.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Use VideoToolbox hardware encoding", isOn: $hardwareEncoding)
                Text("Turning off Preserve video quality enables 1080p H.264 compatibility conversion, HDR to SDR, and bitmap subtitles. Unsupported formats also use this conversion.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Track preferences") {
                Picker("Audio", selection: $preferredAudioLanguage) {
                    Text("File default").tag("default")
                    Text("Original audio").tag("original")
                    ForEach(trackLanguages, id: \.code) { language in
                        Text(verbatim: language.name).tag(language.code)
                    }
                }
                Picker("Subtitles", selection: $preferredSubtitleLanguage) {
                    Text("Automatic").tag("automatic")
                    Text("Off").tag("off")
                    ForEach(trackLanguages, id: \.code) { language in
                        Text(verbatim: language.name).tag(language.code)
                    }
                }
                Text("Applies when opening a video. If the preferred language is missing, Beamly uses the file’s default audio and turns subtitles off. Manual choices stay until another video is opened.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Original audio requires an original-track marker in the file. Automatic subtitles select a matching adjacent file when the choice is unambiguous.")
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
                Text("FFmpeg and ffprobe are included with Beamly. Choose a folder only to use your own build.")
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
