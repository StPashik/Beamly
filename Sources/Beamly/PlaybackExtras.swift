import AppKit
import BeamlyCore
import SwiftUI

struct WatchHistoryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if model.watchHistory.isEmpty {
                ContentUnavailableView("No watch history", systemImage: "clock", description: Text("Videos you watch will appear here."))
            } else {
                List {
                    historySection("Continue watching", entries: model.watchHistory.filter { !$0.isFinished })
                    historySection("Watched", entries: model.watchHistory.filter(\.isFinished))
                }
            }
            HStack {
                Text("History stays on this Mac. Up to 100 videos are kept.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear history", role: .destructive, action: model.clearHistory).disabled(model.watchHistory.isEmpty)
            }.padding(12)
        }.frame(minWidth: 520, minHeight: 320)
    }

    @ViewBuilder private func historySection(_ title: LocalizedStringKey, entries: [WatchHistoryEntry]) -> some View {
        if !entries.isEmpty {
            Section(title) {
                ForEach(entries) { entry in
                    Button {
                        openWindow(id: "main")
                        NSApp.activate()
                        model.resumeHistory(entry.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: entry.isFinished ? "checkmark.circle" : "play.circle").font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.video.title).lineLimit(1)
                                HStack {
                                    Text(mediaTime(entry.video.position) + " / " + mediaTime(entry.video.duration ?? 0))
                                    Text(entry.watchedAt, style: .date)
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .help(entry.video.url.lastPathComponent)
                    .contextMenu {
                        Button("Remove from history", role: .destructive) { model.removeHistory(entry.id) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.id]) }
                    }
                }
            }
        }
    }
}

struct AudioTimingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio timing").font(.headline)
            Stepper(value: Binding(get: { model.audioDelay }, set: model.setAudioDelay), in: -10...10, step: 0.1) {
                Text(String(format: NSLocalizedString("Offset: %@ s", comment: ""), String(format: "%+.1f", locale: Locale.current, model.audioDelay)))
                    .monospacedDigit()
            }
            Text("Positive values play audio later. Saved for this video.").font(.caption).foregroundStyle(.secondary)
            Button("Reset timing") { model.setAudioDelay(0) }.disabled(model.audioDelay == 0)
        }
        .disabled(model.isPreparing || model.current == nil || model.audioOptions.isEmpty)
        .padding(16).frame(width: 280)
    }
}

struct MenuBarRemote: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 5) {
                Text(model.current?.title ?? "Beamly").font(.headline).lineLimit(2)
                Text(model.playbackStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if model.current != nil {
                HStack {
                    Text(mediaTime(model.position))
                    ProgressView(value: min(model.position, max(0, model.duration)), total: max(0.01, model.duration))
                    Text(mediaTime(model.duration))
                }.font(.caption.monospacedDigit())
                HStack(spacing: 22) {
                    control("backward.end.fill", title: "Previous video", action: model.previous)
                    control("gobackward.10", title: "Skip Back 10 Seconds") { model.seek(model.position - 10) }
                    control(model.isPreparing ? "xmark" : model.isPlaying ? "pause.fill" : "play.fill",
                            title: model.isPreparing ? "Cancel preparation" : model.isPlaying ? "Pause" : "Play") {
                        if !model.player.isExternalPlaybackActive { showMain() }
                        model.togglePlay()
                    }
                    control("goforward.10", title: "Skip Forward 10 Seconds") { model.seek(model.position + 10) }
                    control("forward.end.fill", title: "Next video", action: model.next)
                }
                HStack {
                    Image(systemName: "speaker.wave.2").accessibilityHidden(true)
                    Slider(value: $model.volume, in: 0...1).accessibilityLabel("Volume")
                    control("stop.fill", title: "Stop", action: model.stop)
                }
                SleepTimerMenu(model: model)
            }
            Divider()
            HStack {
                Button("Show Beamly", action: showMain)
                Spacer()
                Button("Quit Beamly") { NSApp.terminate(nil) }
            }
        }.padding(18).frame(width: 310)
    }

    private func showMain() { openWindow(id: "main"); NSApp.activate() }

    private func control(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 24) }
            .buttonStyle(.plain).help(LocalizedStringKey(title)).accessibilityLabel(Text(LocalizedStringKey(title)))
    }
}
