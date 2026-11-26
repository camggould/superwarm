import AppKit
import SwiftUI
import SuperwarmKit

/// Renders the popover offscreen in light and dark mode, using real logs.
/// `Superwarm --render-preview /tmp/superwarm` writes today and 30-day views in light and dark, plus the Settings window.
///
/// The view is hosted in an offscreen window and snapshotted with
/// `cacheDisplay`, so native AppKit controls (segmented picker, scroll view)
/// render properly, which SwiftUI's ImageRenderer can't do.
@MainActor
enum PreviewRenderer {
    /// Real logs, or the synthetic demo year with `--demo`.
    static func loadedModel(demo: Bool) async -> AppModel {
        let model = AppModel(autoRefresh: false, demo: demo)
        await model.refresh()
        return model
    }

    static func render(to base: String, demo: Bool = false) async {
        let model = await loadedModel(demo: demo)
        let size = PopoverView.size
        let variants: [(String, NSAppearance.Name, Period)] = [
            ("light", .aqua, .today), ("dark", .darkAqua, .today), ("month-light", .aqua, .month), ("month-dark", .darkAqua, .month),
        ]
        for (suffix, name, period) in variants {
            model.period = period
            let host = NSHostingView(rootView:
                PopoverView()
                    .environment(model)
                    .background(Color(nsColor: .windowBackgroundColor))
            )
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: name)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(600))  // let charts and transitions settle
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(base)-\(suffix).png"))
            }
            window.orderOut(nil)
        }
        // The whole scrolling content, to check sections below the fold.
        model.period = .month
        let tallSize = CGSize(width: PopoverView.size.width, height: 1150)
        let tall = PopoverView(height: tallSize.height)
            .environment(model)
            .background(Color(nsColor: .windowBackgroundColor))
        await capture(tall, size: tallSize, appearance: .aqua, to: "\(base)-month-full.png")

        let settingsSize = CGSize(width: 460, height: 1100)
        let settings = SettingsView()
            .environment(model)
            .environment(Updates())
            .frame(width: settingsSize.width, height: settingsSize.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        await capture(settings, size: settingsSize, appearance: .aqua, to: "\(base)-settings.png")
    }

    /// `Superwarm --render-review /tmp/review` writes one PNG per slide.
    static func renderReview(to base: String, demo: Bool = false) async {
        let model = await loadedModel(demo: demo)
        guard let snapshot = model.snapshot else {
            print(model.engineError ?? "No snapshot")
            return
        }
        let review = snapshot.review
        let slides = SlideDeck.make(review, snapshot: snapshot)
        if let card = ShareCard.image(review: review, snapshot: snapshot), let png = ShareCard.pngData(card) {
            try? png.write(to: URL(fileURLWithPath: "\(base)-share-card.png"))
        }
        for (index, slide) in slides.enumerated() where slide.id != "share" {
            let view = SlideView(slide: slide, index: index, count: slides.count)
                .frame(width: YearInReviewView.size.width, height: YearInReviewView.size.height)
            await capture(view, size: YearInReviewView.size, appearance: .aqua,
                           to: "\(base)-\(String(format: "%02d", index))-\(slide.id).png")
        }
        if let index = slides.firstIndex(where: { $0.id == "share" }) {
            let page = SharePage(review: review, snapshot: snapshot, index: index, count: slides.count)
                .frame(width: YearInReviewView.size.width, height: YearInReviewView.size.height)
            await capture(page, size: YearInReviewView.size, appearance: .darkAqua,
                           to: "\(base)-\(String(format: "%02d", index))-share.png")
        }
    }

    private static func capture<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to path: String) async {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(400))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
    }
}
