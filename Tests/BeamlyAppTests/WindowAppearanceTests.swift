import AppKit
import AVKit
import SwiftUI
import XCTest
@testable import Beamly

final class WindowAppearanceTests: XCTestCase {
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
            let preview = NSHostingView(rootView: PlaybackPreview(image: image, isPreparing: false).frame(width: 144, height: 81))
            preview.layoutSubtreeIfNeeded()
            XCTAssertFalse(containsPlayerView(preview))
        }
    }

    @MainActor
    private func containsPlayerView(_ view: NSView) -> Bool {
        view is AVPlayerView || view.subviews.contains { containsPlayerView($0) }
    }
}
