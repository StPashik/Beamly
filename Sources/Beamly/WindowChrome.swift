import AppKit
import SwiftUI

struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct GlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

struct WindowChrome: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ChromeView, context: Context) { view.onWindow = onWindow }

    final class ChromeView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        private weak var configuredWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, configuredWindow !== window else { return }
            configuredWindow = window
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            // Publishing SwiftUI state while attaching an NSView causes an update cycle.
            DispatchQueue.main.async { [weak self, weak window] in
                if let window { self?.onWindow?(window) }
            }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) }
            else { window?.performDrag(with: event) }
        }
    }
}

struct WindowControls: View {
    let window: NSWindow?
    @State private var hovering = false

    var body: some View {
        if #available(macOS 15.0, *) {
            buttons.allowsWindowActivationEvents()
        } else {
            buttons
        }
    }

    private var buttons: some View {
        HStack(spacing: 4) {
            control("xmark", color: Color(red: 1, green: 0.37, blue: 0.37), label: "Закрыть окно") { window?.performClose(nil) }
            control("minus", color: Color(red: 1, green: 0.75, blue: 0.23), label: "Свернуть окно") { window?.miniaturize(nil) }
            control("arrow.up.left.and.arrow.down.right", color: Color(red: 0.24, green: 0.80, blue: 0.43), label: "Развернуть окно") {
                if NSEvent.modifierFlags.contains(.option) { window?.performZoom(nil) }
                else { window?.toggleFullScreen(nil) }
            }
        }
        .onHover { hovering = $0 }
    }

    private func control(_ symbol: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(color.gradient)
                .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                .overlay {
                    Image(systemName: symbol).font(.system(size: 7, weight: .bold)).foregroundStyle(.black.opacity(0.65)).opacity(hovering ? 1 : 0)
                }
                .frame(width: 11, height: 11)
                .frame(width: 16, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}
