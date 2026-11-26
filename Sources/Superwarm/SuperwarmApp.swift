import AppKit
import SwiftUI
import SuperwarmCore

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(where: { $0 == "--render-preview" || $0 == "--render-review" }), args.count > flag + 1 {
            // Developer aid: render the popover or the year-in-review slides to PNGs.
            let base = args[flag + 1]
            let review = args[flag] == "--render-review"
            let demo = args.contains("--demo")
            let app = NSApplication.shared
            Task { @MainActor in
                if review {
                    await PreviewRenderer.renderReview(to: base, demo: demo)
                } else {
                    await PreviewRenderer.render(to: base, demo: demo)
                }
                exit(0)
            }
            app.run()
        } else {
            SuperwarmApp.main()
        }
    }
}

struct SuperwarmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var updates = Updates()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
                .environment(updates)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .environment(updates)
        }

        Window("Year in Carbon", id: "year-in-review") {
            YearInReviewView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Window("How Superwarm estimates", id: "methodology") {
            MethodologyView()
                .environment(model)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon even when run outside an .app bundle.
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: Logo.menuBar)
            if let title = model.menuBarTitle {
                Text(title).monospacedDigit()
            }
        }
        .accessibilityLabel(model.menuBarTitle.map { "Superwarm, \($0) CO2e" } ?? "Superwarm")
    }
}

@MainActor
enum Logo {
    private static let source: NSImage = {
        guard let url = Bundle.module.url(forResource: "Logo", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return NSImage(systemSymbolName: "leaf", accessibilityDescription: nil)! }
        return image
    }()

    /// White-on-transparent glyph used as a template, so macOS tints it for the menu bar.
    static let menuBar: NSImage = template(size: 16)

    static func template(size: CGFloat) -> NSImage {
        let image = source.copy() as! NSImage
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}
