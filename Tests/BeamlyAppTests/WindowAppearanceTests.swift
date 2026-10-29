import AppKit
import AVKit
import BeamlyCore
import SwiftUI
import XCTest
@testable import Beamly

final class WindowAppearanceTests: XCTestCase {
    @MainActor
    func testHistoryUsesBeamlyWindowMaterialAndChromeInBothAppearances() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-history-window-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var playlist = Playlist()
        playlist.append([folder.appendingPathComponent("Continue.mp4"), folder.appendingPathComponent("Watched.mp4")])
        for index in playlist.items.indices {
            playlist.items[index].duration = 120
            playlist.items[index].position = index == 0 ? 20 : 120
            playlist.recordHistory(playlist.items[index])
        }
        let state = folder.appendingPathComponent("queue.json")
        try JSONEncoder().encode(playlist).write(to: state)
        let suite = "app.beamly.history-window.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(stateURL: state, defaults: defaults)
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        for scheme in [ColorScheme.light, .dark] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 674, height: 460), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = NSHostingView(rootView: WatchHistoryView(model: model).environment(\.colorScheme, scheme))
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            func containsMaterial(_ view: NSView) -> Bool {
                view is NSVisualEffectView || view.subviews.contains(where: containsMaterial)
            }
            XCTAssertTrue(window.contentView.map(containsMaterial) ?? false)
            XCTAssertFalse(window.isOpaque)
            XCTAssertEqual(window.backgroundColor.alphaComponent, 0)
            XCTAssertTrue(window.standardWindowButton(.closeButton)?.isHidden == true)
            XCTAssertEqual(window.contentMinSize.width, 674)
            XCTAssertEqual(window.contentMaxSize.width, 674)
            XCTAssertEqual(model.watchHistory.count, 2, "Restyling must preserve history")
        }
    }

    @MainActor
    func testCustomChromeKeepsNativeWindowActionsAndClearsOpaqueBackground() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 674, height: 390), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        defer { window.close() }
        window.contentView = WindowChrome.ChromeView()

        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor.alphaComponent, 0)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.standardWindowButton(.closeButton)?.isHidden == true)
        XCTAssertTrue(window.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        XCTAssertTrue(window.standardWindowButton(.zoomButton)?.isHidden == true)
        XCTAssertEqual(window.contentMinSize.width, 674)
        XCTAssertEqual(window.contentMaxSize.width, 674)
        XCTAssertGreaterThan(window.contentMaxSize.height, window.contentMinSize.height)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenNone))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenPrimary))
        window.performZoom(nil)
        XCTAssertEqual(window.contentView?.bounds.width ?? 0, 674, accuracy: 0.5)
    }

    @MainActor
    func testPreviewNeverEmbedsALivePlayer() {
        _ = NSApplication.shared
        for image in [nil, NSImage(systemSymbolName: "film", accessibilityDescription: nil)] {
            let preview = NSHostingView(rootView: PlaybackPreview(image: image).frame(width: 144, height: 81))
            preview.layoutSubtreeIfNeeded()
            XCTAssertFalse(containsPlayerView(preview))
        }
    }

    @MainActor
    func testPlayPickerRequestOpensOnceAndDoesNotToggleAnOpenBubble() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let picker = PressablePicker()
        window.contentView = picker
        let coordinator = AirPlayPicker.Coordinator()
        var requested = false
        let request = Binding(get: { requested }, set: { requested = $0 })
        coordinator.presentRoutes(in: picker, request: request)
        requested = true
        coordinator.presentRoutes(in: picker, request: request)
        coordinator.presentRoutes(in: picker, request: request)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(picker.presses, 1)
        XCTAssertFalse(requested)

        coordinator.routePickerViewWillBeginPresentingRoutes(picker)
        requested = true
        coordinator.presentRoutes(in: picker, request: request)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(picker.presses, 1)
        XCTAssertFalse(requested)

        coordinator.routePickerViewDidEndPresentingRoutes(picker)
        requested = true
        coordinator.presentRoutes(in: picker, request: request)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(picker.presses, 2)
        XCTAssertFalse(requested)
    }

    @MainActor
    private func containsPlayerView(_ view: NSView) -> Bool {
        view is AVPlayerView || view.subviews.contains { containsPlayerView($0) }
    }
}

@MainActor
private final class PressablePicker: AVRoutePickerView {
    var presses = 0
    override func accessibilityPerformPress() -> Bool { presses += 1; return true }
}
