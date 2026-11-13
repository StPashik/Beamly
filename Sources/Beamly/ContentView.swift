import AppKit
import BeamlyCore
import SwiftUI
import UniformTypeIdentifiers

let beamlyAccent = NSColor(name: "BeamlyAccent") { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(red: 0.26, green: 0.78, blue: 0.62, alpha: 1)
        : NSColor(red: 0.02, green: 0.43, blue: 0.31, alpha: 1)
}
let beamlyAccentColor = Color(nsColor: beamlyAccent)

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var dropping = false
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    @State private var window: NSWindow?
    @State private var showSubtitleTiming = false
    @State private var showAudioTiming = false

    var body: some View {
        VStack(spacing: 0) {
            destination
            if let movie = model.current {
                movieInfo(movie)
                PlaybackControls(model: model, scrubbing: $scrubbing, scrubPosition: $scrubPosition,
                                 showSubtitleTiming: $showSubtitleTiming, showAudioTiming: $showAudioTiming)
                QueueView(model: model)
                    .padding(.horizontal, 14).padding(.bottom, 14)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 674, idealWidth: 674, maxWidth: 674, minHeight: 360, idealHeight: 390)
        .background {
            WindowMaterial()
            RadialGradient(colors: [beamlyAccentColor.opacity(colorScheme == .dark ? 0.10 : 0.07), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.6), lineWidth: 0.5).allowsHitTesting(false))
        .ignoresSafeArea(.container, edges: .top)
        .tint(beamlyAccentColor)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 10).fill(beamlyAccentColor.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(beamlyAccentColor, style: StrokeStyle(lineWidth: 2, dash: [7])))
                    .allowsHitTesting(false).padding(5)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping, perform: dropFiles)
        .alert("Beamly", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var destination: some View {
        HStack(spacing: 14) {
            WindowControls(window: window)
            HStack(spacing: 7) {
                Image(systemName: "play.rectangle.fill").font(.system(size: 13)).foregroundStyle(beamlyAccentColor)
                Text("Beamly").font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            Spacer()
            Button { openWindow(id: "history") } label: { Image(systemName: "clock.arrow.circlepath").frame(width: 24, height: 25) }
                .buttonStyle(.plain).help("Watch history").accessibilityLabel("Watch history")
            HStack(spacing: 7) {
                if model.isExternal { Circle().fill(beamlyAccentColor).frame(width: 5, height: 5).accessibilityHidden(true) }
                Text("AirPlay").font(.system(size: 11, weight: .medium))
                AirPlayPicker(player: model.player, request: $model.isAirPlayPickerRequested,
                              onPresentationChanged: model.airPlayPickerPresentationChanged)
                    .frame(width: 24, height: 25)
                    .accessibilityLabel("Choose an AirPlay device")
            }
            .padding(.leading, 12).padding(.trailing, 5).padding(.vertical, 2)
            .modifier(GlassSurface(cornerRadius: 20))
            .help(model.status)
        }
        .padding(.horizontal, 16).frame(height: 48)
        .background(WindowChrome { window = $0 })
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            Button(action: model.openFiles) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .light)).foregroundStyle(beamlyAccentColor)
                    .frame(width: 60, height: 60)
                    .modifier(GlassSurface(cornerRadius: 19))
            }
            .buttonStyle(.plain).accessibilityLabel("Add videos")
            Text("Drop videos here")
                .font(.system(size: 18, weight: .medium, design: .rounded)).padding(.top, 20)
            Button("Choose videos to play on your TV", action: model.openFiles)
                .buttonStyle(.plain).foregroundStyle(beamlyAccentColor)
                .font(.system(size: 12)).padding(.top, 7)
            HStack(spacing: 7) {
                ForEach(["MP4", "MKV", "M4V", "MOV", "AVI", "M2TS"], id: \.self) { format in
                    Text(format).font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 4))
                }
            }.padding(.top, 25)
            Spacer(minLength: 25)
            Text("From your Mac to the big screen").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.bottom, 23)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func movieInfo(_ movie: PlaylistItem) -> some View {
        HStack(spacing: 17) {
            PlaybackPreview(image: model.previewImage)
                .frame(width: 144, height: 81)
            VStack(alignment: .leading, spacing: 6) {
                Text(movie.title).font(.system(size: 14, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(movie.url.pathExtension.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 3).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
                    if let info = model.info {
                        if info.width > 0 { Text("\(info.width) × \(info.height)") }
                        if let codec = info.videoCodec { Text(codec.uppercased()) }
                        if info.hasDolbyVision { Text("Dolby Vision") }
                        else if info.isHDR { Text(info.videoRange == "PQ" ? "HDR10" : "HLG") }
                    }
                    if model.duration > 0 { Text(mediaTime(model.duration)) }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if model.isPreparing || model.isBuffering {
                        ProgressView().controlSize(.mini).frame(width: 10, height: 10).accessibilityHidden(true)
                    }
                    Text(model.playbackStatus).lineLimit(1).help(model.playbackStatus)
                }
                .font(.system(size: 10)).foregroundStyle(model.isPreparing || model.isBuffering ? .secondary : beamlyAccentColor)
                if let title = model.qualityTitle {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).help(title)
                        if let explanation = model.qualityExplanation { Text(explanation).help(explanation) }
                    }
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 22).frame(height: 116)
    }

    private func dropFiles(_ providers: [NSItemProvider]) -> Bool {
        Task {
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let url = item as? URL { continuation.resume(returning: url) }
                        else if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                        else { continuation.resume(returning: nil) }
                    }
                }
                if let url { urls.append(url) }
            }
            if !urls.isEmpty { model.add(urls) }
        }
        return true
    }
}

#if DEBUG
#Preview { ContentView(model: AppModel(stateURL: FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-empty-preview.json"))) }

#Preview("Queue") {
    let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-queue-preview.json")
    var playlist = Playlist()
    playlist.append([URL(fileURLWithPath: "/tmp/Big Buck Bunny.mp4"), URL(fileURLWithPath: "/tmp/Sintel.mkv"), URL(fileURLWithPath: "/tmp/Tears of Steel.mov")])
    playlist.items[0].duration = 596
    playlist.items[0].position = 83
    playlist.items[1].duration = 888
    playlist.items[2].duration = 734
    try? JSONEncoder().encode(playlist).write(to: stateURL, options: .atomic)
    return ContentView(model: AppModel(stateURL: stateURL))
}
#endif
