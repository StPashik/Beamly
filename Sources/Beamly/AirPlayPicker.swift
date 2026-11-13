import AVKit
import SwiftUI

struct AirPlayPicker: NSViewRepresentable {
    let player: AVPlayer
    @Binding var request: Bool
    let onPresentationChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPresentationChanged: onPresentationChanged) }

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
        private let onPresentationChanged: (Bool) -> Void

        init(onPresentationChanged: @escaping (Bool) -> Void) {
            self.onPresentationChanged = onPresentationChanged
        }

        func presentRoutes(in view: AVRoutePickerView, request: Binding<Bool>) {
            guard request.wrappedValue, !presentationScheduled else { return }
            presentationScheduled = true
            DispatchQueue.main.async {
                self.presentationScheduled = false
                guard request.wrappedValue, let window = view.window else { return }
                request.wrappedValue = false
                guard !self.isPresenting else { return }
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                Self.press(in: view)
            }
        }

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            isPresenting = true
            onPresentationChanged(true)
        }

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            isPresenting = false
            onPresentationChanged(false)
        }

        @discardableResult
        static func press(in view: NSView) -> Bool {
            // shortcut: AVKit has no macOS presentation method; replace this bridge when it provides one.
            if view.accessibilityPerformPress() { return true }
            return view.subviews.contains { press(in: $0) }
        }
    }
}
