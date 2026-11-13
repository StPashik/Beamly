import AppKit
import BeamlyCore
import SwiftUI

struct PlaybackControls: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Binding var scrubbing: Bool
    @Binding var scrubPosition: Double
    @Binding var showSubtitleTiming: Bool
    @Binding var showAudioTiming: Bool

    var body: some View {
        HStack(spacing: 10) {
            iconButton("backward.end.fill", title: "Previous video", action: model.previous)
                .font(.system(size: 10))
            Button(action: model.togglePlay) {
                Image(systemName: model.isPreparing ? "xmark" : model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34)
                    .background(beamlyAccentColor.gradient, in: Circle()).foregroundStyle(colorScheme == .dark ? Color(red: 0.03, green: 0.20, blue: 0.15) : .white)
            }.buttonStyle(.plain).accessibilityLabel(Text(LocalizedStringKey(model.isPreparing ? "Cancel preparation" : model.isPlaying ? "Pause" : "Play")))
            iconButton("forward.end.fill", title: "Next video", action: model.next)
                .font(.system(size: 10))
            Text(mediaTime(scrubbing ? scrubPosition : model.position)).monospacedDigit().font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 43, alignment: .trailing)
            SeekTimeline(model: model, scrubbing: $scrubbing, position: $scrubPosition)
            Text("−" + mediaTime(max(0, model.duration - (scrubbing ? scrubPosition : model.position))))
                .monospacedDigit().font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            audioMenu
            subtitleMenu
            ChapterMenu(model: model).labelStyle(.iconOnly)
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            SleepTimerMenu(model: model).labelStyle(.iconOnly)
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
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
            Button("Audio timing…") { showAudioTiming = true }.disabled(model.audioOptions.isEmpty)
        } label: { Image(systemName: "waveform").frame(width: 20) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.isPreparing)
        .help("Audio tracks").accessibilityLabel("Audio tracks")
        .popover(isPresented: $showAudioTiming) { AudioTimingView(model: model) }
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
        } label: { Image(systemName: "captions.bubble").foregroundStyle(model.subtitleID != nil || model.externalSubtitle != nil ? beamlyAccentColor : .primary).frame(width: 20) }
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

    private func iconButton(_ symbol: String, title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 18, height: 23) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

struct SleepTimerMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            if let description = model.sleepTimerDescription {
                Text(description)
                Divider()
            }
            Button { model.setSleepTimer(nil) } label: {
                Label("Off", systemImage: model.sleepTimerRemaining == nil ? "checkmark" : "")
            }
            ForEach([15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                Button(String(format: NSLocalizedString("%d min", comment: ""), minutes)) { model.setSleepTimer(Double(minutes) * 60) }
            }
        } label: {
            Label("Sleep Timer", systemImage: "timer").foregroundStyle(model.sleepTimerRemaining == nil ? Color.secondary : beamlyAccentColor)
        }
        .disabled(model.current == nil)
        .help(model.sleepTimerDescription ?? NSLocalizedString("Sleep Timer", comment: ""))
        .accessibilityLabel("Sleep Timer")
    }
}

struct ChapterMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(model.chapters) { chapter in
                Button { model.seekChapter(chapter.id) } label: {
                    Label("\(mediaTime(chapter.start))  \(model.chapterTitle(chapter))",
                          systemImage: model.chapter(at: model.position)?.id == chapter.id ? "checkmark" : "")
                }
            }
        } label: { Label("Chapters", systemImage: "list.bullet.rectangle") }
        .disabled(model.isPreparing || model.chapters.isEmpty)
        .help("Chapters").accessibilityLabel("Chapters")
    }
}

struct SeekTimeline: View {
    @ObservedObject var model: AppModel
    @Binding var scrubbing: Bool
    @Binding var position: Double
    @State private var hoveredPosition: Double?
    @State private var knobInset = CGFloat.zero

    private var previewPosition: Double? {
        guard !model.isPreparing, model.duration > 0 else { return nil }
        return scrubbing ? position : hoveredPosition
    }

    var body: some View {
        GeometryReader { geometry in
            Slider(value: Binding(get: { scrubbing ? position : min(model.position, max(1, model.duration)) }, set: { position = $0 }),
                   in: 0...max(1, model.duration), onEditingChanged: { editing in
                if editing { position = model.position; scrubbing = true }
                else {
                    guard scrubbing else { return }
                    if hoveredPosition != nil { hoveredPosition = position }
                    scrubbing = false
                    model.seek(position)
                }
            })
            .controlSize(.mini)
            .accessibilityLabel("Playback position")
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoveredPosition = Self.time(at: point.x, width: geometry.size.width, duration: model.duration, inset: knobInset)
                case .ended: hoveredPosition = nil
                }
            }
            .overlay(alignment: .bottomLeading) {
                if previewPosition != nil, let seconds = model.seekPreviewTime {
                    SeekPreview(model: model, seconds: seconds)
                        .offset(x: Self.previewOrigin(at: seconds, width: geometry.size.width, duration: model.duration, inset: knobInset), y: -24)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }
        .frame(height: 16)
        .disabled(model.isPreparing || model.duration <= 0)
        .onAppear {
            let sizing = NSSlider(frame: NSRect(x: 0, y: 0, width: 100, height: 16))
            sizing.controlSize = .mini
            knobInset = sizing.knobThickness / 2
        }
        .onChange(of: previewPosition) { _, seconds in model.requestSeekPreview(seconds) }
        .onChange(of: model.current?.id) { _, _ in hoveredPosition = nil; scrubbing = false }
        .onChange(of: model.isPreparing) { _, preparing in
            if preparing { hoveredPosition = nil; scrubbing = false }
        }
        .onDisappear { model.requestSeekPreview(nil) }
    }

    static func time(at x: CGFloat, width: CGFloat, duration: Double, inset: CGFloat = 0) -> Double? {
        guard x.isFinite, width.isFinite, inset.isFinite, inset >= 0, width > 2 * inset, duration.isFinite, duration > 0 else { return nil }
        return min(1, max(0, (x - inset) / (width - 2 * inset))) * duration
    }

    static func previewOrigin(at seconds: Double, width: CGFloat, duration: Double, inset: CGFloat = 0) -> CGFloat {
        guard seconds.isFinite, width.isFinite, inset.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(0, width - 160), max(0, inset + seconds / duration * max(0, width - 2 * inset) - 80))
    }
}

struct SeekPreview: View {
    @ObservedObject var model: AppModel
    let seconds: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let image = model.seekPreviewImage { Image(nsImage: image).resizable().scaledToFit() }
                else if model.isLoadingSeekPreview { ProgressView().controlSize(.small) }
                else { Text("Preview unavailable").font(.system(size: 10)).foregroundStyle(Color(nsColor: .secondaryLabelColor)) }
            }
            .frame(width: 144, height: 81)
            .background(.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(mediaTime(seconds)).monospacedDigit().font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(nsColor: .labelColor))
                if let chapter = model.chapter(at: seconds) {
                    Text(model.chapterTitle(chapter)).font(.system(size: 10)).foregroundStyle(Color(nsColor: .secondaryLabelColor)).lineLimit(1)
                }
            }
        }
        .padding(8).frame(width: 160, alignment: .leading)
        .modifier(GlassSurface(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }
}

struct PlaybackPreview: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(beamlyAccentColor.opacity(0.045))
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").font(.system(size: 24, weight: .ultraLight)).foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(beamlyAccentColor.opacity(0.12), lineWidth: 0.5))
        .accessibilityLabel("Frame from the middle of the video")
    }
}
