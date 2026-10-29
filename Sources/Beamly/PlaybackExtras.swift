import AppKit
import BeamlyCore
import SwiftUI

struct WatchHistoryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @State private var window: NSWindow?
    private let accent = Color(nsColor: beamlyAccent)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                WindowControls(window: window)
                Label("Watch history", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                Text("\(model.watchHistory.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).frame(height: 48)
            .background(WindowChrome { window = $0 })
            if model.watchHistory.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock").font(.system(size: 24, weight: .light)).foregroundStyle(accent)
                        .frame(width: 60, height: 60).modifier(GlassSurface(cornerRadius: 19)).accessibilityHidden(true)
                    Text("No watch history").font(.system(size: 18, weight: .medium, design: .rounded))
                    Text("Videos you watch will appear here.").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        historySection("Continue watching", entries: model.watchHistory.filter { !$0.isFinished })
                        historySection("Watched", entries: model.watchHistory.filter(\.isFinished))
                    }.padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 14)
                }
            }
            HStack(spacing: 16) {
                Text("History stays on this Mac. Up to 100 videos are kept.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear history", role: .destructive, action: model.clearHistory)
                    .font(.system(size: 11, weight: .medium)).buttonStyle(.plain).foregroundStyle(.primary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .modifier(GlassSurface(cornerRadius: 14)).disabled(model.watchHistory.isEmpty)
            }.padding(.horizontal, 18).padding(.bottom, 14).padding(.top, 4)
        }
        .frame(minWidth: 674, idealWidth: 674, maxWidth: 674, minHeight: 360)
        .background {
            WindowMaterial()
            RadialGradient(colors: [accent.opacity(colorScheme == .dark ? 0.10 : 0.07), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.6), lineWidth: 0.5).allowsHitTesting(false))
        .ignoresSafeArea(.container, edges: .top)
        .tint(accent)
    }

    @ViewBuilder private func historySection(_ title: LocalizedStringKey, entries: [WatchHistoryEntry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 12)
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        Button {
                            openWindow(id: "main")
                            NSApp.activate()
                            model.resumeHistory(entry.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: entry.isFinished ? "checkmark.circle" : "play.circle.fill")
                                    .font(.system(size: 22, weight: .light)).foregroundStyle(accent)
                                    .frame(width: 28).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(entry.video.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    HStack {
                                        Text(mediaTime(entry.video.position) + " / " + mediaTime(entry.video.duration ?? 0)).monospacedDigit()
                                        Spacer()
                                        Text(entry.watchedAt, style: .date)
                                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                                    if !entry.isFinished {
                                        ProgressView(value: entry.video.position, total: max(0.01, entry.video.duration ?? 0))
                                            .controlSize(.mini).accessibilityHidden(true)
                                    }
                                }
                            }
                            .foregroundStyle(.primary).padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .help(entry.video.url.lastPathComponent)
                        .contextMenu {
                            Button("Remove from history", role: .destructive) { model.removeHistory(entry.id) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.id]) }
                        }
                        if entry.id != entries.last?.id { Divider().opacity(0.4).padding(.leading, 54) }
                    }
                }.modifier(GlassSurface(cornerRadius: 18))
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
