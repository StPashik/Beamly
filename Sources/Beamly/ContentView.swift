import AVKit
import BeamlyCore
import SwiftUI
import UniformTypeIdentifiers

private let beamlyAccent = NSColor(name: "BeamlyAccent") { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(red: 0.26, green: 0.78, blue: 0.62, alpha: 1)
        : NSColor(red: 0.02, green: 0.43, blue: 0.31, alpha: 1)
}
private let mint = Color(nsColor: beamlyAccent)

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var dropping = false
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    @State private var window: NSWindow?
    @State private var showSubtitleTiming = false

    var body: some View {
        VStack(spacing: 0) {
            destination
            if let movie = model.current {
                movieInfo(movie)
                transport
                queue
                    .padding(.horizontal, 14).padding(.bottom, 14)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 674, idealWidth: 674, maxWidth: 674, minHeight: 360, idealHeight: 390)
        .background {
            WindowMaterial()
            RadialGradient(colors: [mint.opacity(colorScheme == .dark ? 0.10 : 0.07), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.6), lineWidth: 0.5).allowsHitTesting(false))
        .ignoresSafeArea(.container, edges: .top)
        .tint(mint)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 10).fill(mint.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(mint, style: StrokeStyle(lineWidth: 2, dash: [7])))
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
                Image(systemName: "play.rectangle.fill").font(.system(size: 13)).foregroundStyle(mint)
                Text("Beamly").font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            Spacer()
            HStack(spacing: 7) {
                if model.isExternal { Circle().fill(mint).frame(width: 5, height: 5).accessibilityHidden(true) }
                Text("AirPlay").font(.system(size: 11, weight: .medium))
                AirPlayPicker(player: model.player, request: $model.isAirPlayPickerRequested).frame(width: 24, height: 25)
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
                    .font(.system(size: 24, weight: .light)).foregroundStyle(mint)
                    .frame(width: 60, height: 60)
                    .modifier(GlassSurface(cornerRadius: 19))
            }
            .buttonStyle(.plain).accessibilityLabel("Add videos")
            Text("Drop videos here")
                .font(.system(size: 18, weight: .medium, design: .rounded)).padding(.top, 20)
            Button("Choose videos to play on your TV", action: model.openFiles)
                .buttonStyle(.plain).foregroundStyle(mint)
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
                .font(.system(size: 10)).foregroundStyle(model.isPreparing || model.isBuffering ? .secondary : mint)
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

    private var transport: some View {
        HStack(spacing: 10) {
            iconButton("backward.end.fill", title: "Previous video", action: model.previous)
                .font(.system(size: 10))
            Button(action: model.togglePlay) {
                Image(systemName: model.isPreparing ? "xmark" : model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34)
                    .background(mint.gradient, in: Circle()).foregroundStyle(colorScheme == .dark ? Color(red: 0.03, green: 0.20, blue: 0.15) : .white)
            }.buttonStyle(.plain).accessibilityLabel(Text(LocalizedStringKey(model.isPreparing ? "Cancel preparation" : model.isPlaying ? "Pause" : "Play")))
            iconButton("forward.end.fill", title: "Next video", action: model.next)
                .font(.system(size: 10))
            Text(mediaTime(scrubbing ? scrubPosition : model.position)).monospacedDigit().font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 43, alignment: .trailing)
            Slider(value: Binding(get: { scrubbing ? scrubPosition : min(model.position, max(1, model.duration)) }, set: { scrubPosition = $0 }), in: 0...max(1, model.duration), onEditingChanged: { editing in
                if editing { scrubPosition = model.position; scrubbing = true }
                else { scrubbing = false; model.seek(scrubPosition) }
            })
            .controlSize(.mini).disabled(model.isPreparing || model.duration <= 0)
            .accessibilityLabel("Playback position")
            Text("−" + mediaTime(max(0, model.duration - (scrubbing ? scrubPosition : model.position))))
                .monospacedDigit().font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            audioMenu
            subtitleMenu
        }
        .padding(.horizontal, 16).frame(height: 54)
        .modifier(GlassSurface(cornerRadius: 18))
        .padding(.horizontal, 14).padding(.bottom, 12)
    }

    private var audioMenu: some View {
        Menu {
            Button { model.setAudio(nil) } label: { Label("Default", systemImage: model.audioID == nil ? "checkmark" : "") }
            ForEach(model.audioOptions) { track in
                Button { model.setAudio(track.id) } label: { Label(track.title, systemImage: model.audioID == track.id ? "checkmark" : "") }
            }
            Divider()
            Picker("Volume", selection: $model.volume) {
                ForEach([0, 25, 50, 75, 100], id: \.self) { value in Text("\(value)%").tag(Double(value) / 100) }
            }
        } label: { Image(systemName: model.volume == 0 ? "speaker.slash" : "speaker.wave.2").frame(width: 20) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.isPreparing)
        .help("Audio and volume").accessibilityLabel("Audio and volume")
    }

    private var subtitleMenu: some View {
        Menu {
            Button { model.setSubtitle(nil) } label: { Label("Off", systemImage: model.subtitleID == nil && model.externalSubtitle == nil ? "checkmark" : "") }
            ForEach(model.subtitleOptions) { track in
                Button { model.setSubtitle(track.id) } label: { Label(track.title, systemImage: model.subtitleID == track.id ? "checkmark" : "") }
            }
            ForEach(model.externalSubtitleOptions, id: \.self) { file in
                Button { model.attachSubtitle(file) } label: {
                    Label(file.lastPathComponent, systemImage: model.externalSubtitle == file ? "checkmark" : "")
                }
            }
            if let external = model.externalSubtitle, !model.externalSubtitleOptions.contains(external) {
                Label(external.lastPathComponent, systemImage: "checkmark")
            }
            Divider()
            Button("Add subtitle file…", action: model.chooseSubtitle)
            Button("Subtitle timing…") { showSubtitleTiming = true }
                .disabled(model.subtitleID == nil && model.externalSubtitle == nil)
        } label: { Image(systemName: "captions.bubble").foregroundStyle(model.subtitleID != nil || model.externalSubtitle != nil ? mint : .primary).frame(width: 20) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.isPreparing)
        .help("Subtitles").accessibilityLabel("Subtitles")
        .popover(isPresented: $showSubtitleTiming) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Subtitle timing").font(.headline)
                Stepper(value: Binding(get: { model.subtitleDelay }, set: model.setSubtitleDelay), step: 0.5) {
                    Text(String(format: NSLocalizedString("Offset: %@ s", comment: ""), String(format: "%+.1f", locale: Locale.current, model.subtitleDelay)))
                        .monospacedDigit()
                }
                Text("Positive values show subtitles later.").font(.caption).foregroundStyle(.secondary)
                Button("Reset timing") { model.setSubtitleDelay(0) }.disabled(model.subtitleDelay == 0)
            }
            .disabled(model.isPreparing || (model.subtitleID == nil && model.externalSubtitle == nil))
            .padding(16).frame(width: 280)
        }
    }

    private var queue: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Text("QUEUE").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.tertiary)
                Text("\(model.playlist.items.count)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                Spacer()
                iconButton("shuffle", title: "Shuffle", action: model.toggleShuffle).foregroundStyle(model.playlist.shuffle ? mint : .secondary)
                Menu {
                    Button("Off") { model.setRepeat(.off) }
                    Button("One video") { model.setRepeat(.one) }
                    Button("Entire queue") { model.setRepeat(.all) }
                } label: { Image(systemName: model.playlist.repeatMode == .one ? "repeat.1" : "repeat").foregroundStyle(model.playlist.repeatMode == .off ? .secondary : mint) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Repeat").accessibilityLabel("Repeat")
                .tint(model.playlist.repeatMode == .off ? Color.secondary : mint)
                Button("Add…", action: model.openFiles).buttonStyle(.plain).help("Add videos ⌘O")
                Button("Clear", action: model.clear).buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 4)
            }
            .font(.system(size: 10)).padding(.horizontal, 13).frame(height: 31)
            List(selection: Binding(get: { model.playlist.currentID }, set: { id in
                if let id, id != model.playlist.currentID { model.select(id) }
            })) {
                ForEach(Array(model.playlist.items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 11) {
                        Group {
                            if item.id == model.current?.id { Image(systemName: model.isPlaying ? "speaker.wave.2.fill" : "play.fill").font(.system(size: 9)).foregroundStyle(mint) }
                            else { Text("\(index + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
                        }.frame(width: 16)
                        Text(item.title).font(.system(size: 11, weight: item.id == model.current?.id ? .medium : .regular)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(item.duration.map(mediaTime) ?? item.url.pathExtension.uppercased()).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                        Menu {
                            Button("Play") { model.select(item.id) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                            Divider()
                            Button("Remove from queue", role: .destructive) { model.remove(item.id) }
                        } label: { Image(systemName: "ellipsis").frame(width: 17, height: 20) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(String(format: NSLocalizedString("Actions for %@", comment: ""), item.title))
                    }
                    .frame(height: 27).contentShape(Rectangle())
                    .tag(item.id)
                    .contextMenu {
                        Button("Play") { model.select(item.id) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        Button("Remove from queue", role: .destructive) { model.remove(item.id) }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 11, bottom: 0, trailing: 11))
                    .listRowBackground(RoundedRectangle(cornerRadius: 7).fill(item.id == model.current?.id ? mint.opacity(0.10) : .clear).padding(.horizontal, 5))
                    .listRowSeparator(.hidden)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(index + 1). \(item.title)")
                }
                .onMove(perform: model.move)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .onDeleteCommand {
                if let id = model.playlist.currentID { model.remove(id) }
            }
            .environment(\.defaultMinListRowHeight, 27)
        }
        .frame(maxHeight: .infinity)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.05), lineWidth: 0.5).allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private func iconButton(_ symbol: String, title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 18, height: 23) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
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

struct AirPlayPicker: NSViewRepresentable {
    let player: AVPlayer
    @Binding var request: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.delegate = context.coordinator
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.secondaryLabelColor, for: .normal)
        view.setRoutePickerButtonColor(beamlyAccent, for: .active)
        return view
    }
    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        if view.player !== player { view.player = player }
        context.coordinator.presentRoutes(in: view, request: $request)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency AVRoutePickerViewDelegate {
        private var presentationScheduled = false
        private var isPresenting = false

        func presentRoutes(in view: AVRoutePickerView, request: Binding<Bool>) {
            guard request.wrappedValue, !presentationScheduled else { return }
            presentationScheduled = true
            DispatchQueue.main.async {
                self.presentationScheduled = false
                guard request.wrappedValue else { return }
                request.wrappedValue = false
                guard !self.isPresenting, let window = view.window else { return }
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                Self.press(in: view)
            }
        }

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) { isPresenting = true }
        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) { isPresenting = false }

        @discardableResult
        static func press(in view: NSView) -> Bool {
            // shortcut: AVKit has no macOS presentation method; replace this bridge when it provides one.
            if view.accessibilityPerformPress() { return true }
            return view.subviews.contains { press(in: $0) }
        }
    }
}

struct PlaybackPreview: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(mint.opacity(0.045))
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").font(.system(size: 24, weight: .ultraLight)).foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(mint.opacity(0.12), lineWidth: 0.5))
        .accessibilityLabel("Frame from the middle of the video")
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
