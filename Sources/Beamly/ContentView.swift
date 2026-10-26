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
        .frame(minWidth: 640, idealWidth: 674, minHeight: 360, idealHeight: 390)
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
                AirPlayPicker(player: model.player).frame(width: 24, height: 25)
                    .accessibilityLabel("Выбрать устройство AirPlay")
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
            .buttonStyle(.plain).accessibilityLabel("Добавить видео")
            Text("Перетащите видео сюда")
                .font(.system(size: 18, weight: .medium, design: .rounded)).padding(.top, 20)
            HStack(spacing: 0) {
                Text("или ").foregroundStyle(.secondary)
                Button("выберите файлы", action: model.openFiles).buttonStyle(.plain).foregroundStyle(mint)
                Text(" для воспроизведения на ТВ").foregroundStyle(.secondary)
            }
            .font(.system(size: 12)).padding(.top, 7)
            HStack(spacing: 7) {
                ForEach(["MP4", "MKV", "M4V", "MOV", "AVI", "M2TS"], id: \.self) { format in
                    Text(format).font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 4))
                }
            }.padding(.top, 25)
            Spacer(minLength: 25)
            Text("С Mac — на большой экран").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.bottom, 23)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func movieInfo(_ movie: PlaylistItem) -> some View {
        HStack(spacing: 17) {
            PlaybackPreview(player: model.player, isExternal: model.isExternal, isPreparing: model.isPreparing)
                .frame(width: 144, height: 81)
            VStack(alignment: .leading, spacing: 8) {
                Text(movie.title).font(.system(size: 14, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(movie.url.pathExtension.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 3).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
                    if let info = model.info {
                        if info.width > 0 { Text("\(info.width) × \(info.height)") }
                        if let codec = info.videoCodec { Text(codec.uppercased()) }
                    }
                    if model.duration > 0 { Text(mediaTime(model.duration)) }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(model.isPreparing ? "Подготовка видео…" : model.player.currentItem == nil ? "Готово к воспроизведению" : model.isPlaying ? "Воспроизводится" : "На паузе")
                    .font(.system(size: 10)).foregroundStyle(model.isPreparing ? .secondary : mint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 22).frame(height: 116)
    }

    private var transport: some View {
        HStack(spacing: 10) {
            iconButton("backward.end.fill", title: "Предыдущее видео", action: model.previous)
                .font(.system(size: 10))
            Button(action: model.togglePlay) {
                Image(systemName: model.isPreparing ? "xmark" : model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34)
                    .background(mint.gradient, in: Circle()).foregroundStyle(colorScheme == .dark ? Color(red: 0.03, green: 0.20, blue: 0.15) : .white)
            }.buttonStyle(.plain).accessibilityLabel(model.isPreparing ? "Отменить подготовку" : model.isPlaying ? "Пауза" : "Воспроизвести")
            iconButton("forward.end.fill", title: "Следующее видео", action: model.next)
                .font(.system(size: 10))
            Text(mediaTime(scrubbing ? scrubPosition : model.position)).monospacedDigit().font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 43, alignment: .trailing)
            Slider(value: Binding(get: { scrubbing ? scrubPosition : min(model.position, max(1, model.duration)) }, set: { scrubPosition = $0 }), in: 0...max(1, model.duration), onEditingChanged: { editing in
                if editing { scrubPosition = model.position; scrubbing = true }
                else { scrubbing = false; model.seek(scrubPosition) }
            })
            .controlSize(.mini).disabled(model.isPreparing || model.duration <= 0)
            .accessibilityLabel("Позиция воспроизведения")
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
            Button { model.setAudio(nil) } label: { Label("По умолчанию", systemImage: model.audioID == nil ? "checkmark" : "") }
            ForEach(model.audioOptions) { track in
                Button { model.setAudio(track.id) } label: { Label(track.title, systemImage: model.audioID == track.id ? "checkmark" : "") }
            }
            Divider()
            Picker("Громкость", selection: $model.volume) {
                ForEach([0, 25, 50, 75, 100], id: \.self) { value in Text("\(value)%").tag(Double(value) / 100) }
            }
        } label: { Image(systemName: model.volume == 0 ? "speaker.slash" : "speaker.wave.2").frame(width: 20) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.isPreparing)
        .help("Аудиодорожка и громкость").accessibilityLabel("Аудиодорожка и громкость")
    }

    private var subtitleMenu: some View {
        Menu {
            Button { model.setSubtitle(nil) } label: { Label("Выключены", systemImage: model.subtitleID == nil && model.externalSubtitle == nil ? "checkmark" : "") }
            ForEach(model.subtitleOptions) { track in
                Button { model.setSubtitle(track.id) } label: { Label(track.title, systemImage: model.subtitleID == track.id ? "checkmark" : "") }
            }
            if let external = model.externalSubtitle { Label(external.lastPathComponent, systemImage: "checkmark") }
            Divider()
            Button("Добавить файл субтитров…", action: model.chooseSubtitle)
        } label: { Image(systemName: "captions.bubble").foregroundStyle(model.subtitleID != nil || model.externalSubtitle != nil ? mint : .primary).frame(width: 20) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.isPreparing)
        .help("Субтитры").accessibilityLabel("Субтитры")
    }

    private var queue: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Text("ОЧЕРЕДЬ").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.tertiary)
                Text("\(model.playlist.items.count)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                Spacer()
                iconButton("shuffle", title: "Перемешивать", action: model.toggleShuffle).foregroundStyle(model.playlist.shuffle ? mint : .secondary)
                Menu {
                    Button("Выключен") { model.setRepeat(.off) }
                    Button("Одно видео") { model.setRepeat(.one) }
                    Button("Вся очередь") { model.setRepeat(.all) }
                } label: { Image(systemName: model.playlist.repeatMode == .one ? "repeat.1" : "repeat").foregroundStyle(model.playlist.repeatMode == .off ? .secondary : mint) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Повтор").accessibilityLabel("Повтор")
                .tint(model.playlist.repeatMode == .off ? Color.secondary : mint)
                Button("Добавить…", action: model.openFiles).buttonStyle(.plain).help("Добавить видео ⌘O")
                Button("Очистить", action: model.clear).buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 4)
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
                            Button("Воспроизвести") { model.select(item.id) }
                            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                            Divider()
                            Button("Удалить из очереди", role: .destructive) { model.remove(item.id) }
                        } label: { Image(systemName: "ellipsis").frame(width: 17, height: 20) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Действия с \(item.title)")
                    }
                    .frame(height: 27).contentShape(Rectangle())
                    .tag(item.id)
                    .contextMenu {
                        Button("Воспроизвести") { model.select(item.id) }
                        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        Button("Удалить из очереди", role: .destructive) { model.remove(item.id) }
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

    private func iconButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
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
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.secondaryLabelColor, for: .normal)
        view.setRoutePickerButtonColor(beamlyAccent, for: .active)
        return view
    }
    func updateNSView(_ view: AVRoutePickerView, context: Context) { view.player = player }
}

struct VideoPreview: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

struct PlaybackPreview: View {
    let player: AVPlayer
    let isExternal: Bool
    let isPreparing: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(mint.opacity(0.045))
            if isExternal {
                VStack(spacing: 8) {
                    Image(systemName: "airplay.video").font(.system(size: 22, weight: .light))
                    Text("AirPlay").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(mint)
            } else if player.currentItem != nil {
                VideoPreview(player: player)
            } else {
                Image(systemName: "play.rectangle").font(.system(size: 24, weight: .ultraLight)).foregroundStyle(.secondary)
            }
            if isPreparing { ProgressView().controlSize(.small) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(mint.opacity(0.12), lineWidth: 0.5))
        .accessibilityLabel(isExternal ? "AirPlay" : "Предпросмотр видео")
    }
}

#if DEBUG
#Preview { ContentView(model: AppModel(stateURL: FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-empty-preview.json"))) }

#Preview("Очередь") {
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
