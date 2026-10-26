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
    }

    @MainActor
    func testAirPlayPreviewDoesNotEmbedTheSystemRemotePlaybackPlaceholder() {
        _ = NSApplication.shared
        let player = AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
        let external = NSHostingView(rootView: PlaybackPreview(player: player, isExternal: true, isPreparing: false).frame(width: 144, height: 81))
        external.layoutSubtreeIfNeeded()
        XCTAssertFalse(containsPlayerView(external))

        let local = NSHostingView(rootView: PlaybackPreview(player: player, isExternal: false, isPreparing: false).frame(width: 144, height: 81))
        local.layoutSubtreeIfNeeded()
        XCTAssertTrue(containsPlayerView(local))
    }

    @MainActor
    private func containsPlayerView(_ view: NSView) -> Bool {
        view is AVPlayerView || view.subviews.contains { containsPlayerView($0) }
    }
}
