import AppKit
import SwiftUI
import SuperwarmCore

/// Renders the popover offscreen in light and dark mode, using real logs.
/// `Superwarm --render-preview /tmp/superwarm` writes `-light.png`, `-dark.png` and `-month-light.png`.
///
/// The view is hosted in an offscreen window and snapshotted with
/// `cacheDisplay`, so native AppKit controls (segmented picker, scroll view)
/// render properly, which SwiftUI's ImageRenderer can't do.
@MainActor
enum PreviewRenderer {
    static func render(to base: String) async {
        let model = AppModel(autoRefresh: false)
        await model.refresh()
        let size = PopoverView.size
        let variants: [(String, NSAppearance.Name, Period)] = [
            ("light", .aqua, .today), ("dark", .darkAqua, .today), ("month-light", .aqua, .month),
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
    }

    /// `Superwarm --render-review /tmp/review` writes one PNG per slide.
    static func renderReview(to base: String) async {
        let model = AppModel(autoRefresh: false)
        await model.refresh()
        guard let report = model.report else { return }
        let year = YearInReview.seasonalYear() ?? Calendar.current.component(.year, from: Date())
        let slides = SlideDeck.make(YearInReview(report: report, year: year), settings: model.settings)
        for (index, slide) in slides.enumerated() {
            let view = SlideView(slide: slide, index: index, count: slides.count)
                .frame(width: YearInReviewView.size.width, height: YearInReviewView.size.height)
            await snapshot(view, size: YearInReviewView.size, appearance: .aqua,
                           to: "\(base)-\(String(format: "%02d", index))-\(slide.id).png")
        }
    }

    private static func snapshot<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to path: String) async {
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
