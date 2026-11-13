import AppKit
import BeamlyCore
import SwiftUI

struct QueueView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Text("QUEUE").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.tertiary)
                Text("\(model.playlist.items.count)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                Spacer()
                Button(action: model.toggleShuffle) { Image(systemName: "shuffle").frame(width: 18, height: 23) }
                    .buttonStyle(.plain).help("Shuffle").accessibilityLabel("Shuffle")
                    .foregroundStyle(model.playlist.shuffle ? beamlyAccentColor : .secondary)
                Menu {
                    Button("Off") { model.setRepeat(.off) }
                    Button("One video") { model.setRepeat(.one) }
                    Button("Entire queue") { model.setRepeat(.all) }
                } label: { Image(systemName: model.playlist.repeatMode == .one ? "repeat.1" : "repeat").foregroundStyle(model.playlist.repeatMode == .off ? .secondary : beamlyAccentColor) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Repeat").accessibilityLabel("Repeat")
                .tint(model.playlist.repeatMode == .off ? Color.secondary : beamlyAccentColor)
                Button("Add…", action: model.openFiles).buttonStyle(.plain).help("Add videos ⌘O")
                Button("Clear", action: model.clear).buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 4)
            }
            .font(.system(size: 10)).padding(.horizontal, 13).frame(height: 31)
            List(selection: Binding(get: { model.playlist.currentID }, set: { id in
                if let id, id != model.playlist.currentID { model.select(id) }
            })) {
                ForEach(Array(model.playlist.items.enumerated()), id: \.element.id) { index, item in
                    row(for: item, at: index)
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

    private func row(for item: PlaylistItem, at index: Int) -> some View {
        HStack(spacing: 11) {
            Group {
                if item.id == model.current?.id { Image(systemName: model.isPlaying ? "speaker.wave.2.fill" : "play.fill").font(.system(size: 9)).foregroundStyle(beamlyAccentColor) }
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
        .listRowBackground(RoundedRectangle(cornerRadius: 7).fill(item.id == model.current?.id ? beamlyAccentColor.opacity(0.10) : .clear).padding(.horizontal, 5))
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(index + 1). \(item.title)")
    }
}
