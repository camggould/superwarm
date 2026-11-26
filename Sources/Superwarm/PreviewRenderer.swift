import AppKit
import SwiftUI

/// Renders the popover offscreen in light and dark mode, using real logs.
/// `Superwarm --render-preview /tmp/superwarm` writes `-light.png` and `-dark.png`.
@MainActor
enum PreviewRenderer {
    static func render(to base: String) async {
        let model = AppModel(autoRefresh: false)
        await model.refresh()
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let appearance = NSAppearance(named: name) else { continue }
            NSApp.appearance = appearance
            appearance.performAsCurrentDrawingAppearance {
                let view = PopoverView()
                    .environment(model)
                    .environment(\.colorScheme, name == .darkAqua ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else { return }
                try? png.write(to: URL(fileURLWithPath: "\(base)-\(suffix).png"))
            }
        }
    }
}
