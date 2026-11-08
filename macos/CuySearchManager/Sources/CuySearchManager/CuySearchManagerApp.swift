import SwiftUI
import AppKit

enum BrandAssets {
    static let menuBarIcon: NSImage = {
        guard
            let url = Bundle.main.url(
                forResource: "MenuBarIconTemplate",
                withExtension: "png"
            ),
            let image = NSImage(contentsOf: url)
        else {
            let fallback = NSImage(
                systemSymbolName: "magnifyingglass.circle",
                accessibilityDescription: "CuySearch"
            ) ?? NSImage()
            fallback.size = NSSize(width: 18, height: 18)
            return fallback
        }
        image.isTemplate = true
        // MenuBarExtra uses the NSImage's point size when laying out the label;
        // the PNG is 128 px for retina rendering, but must occupy 18 pt.
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

@main
struct CuySearchManagerApp: App {
    @StateObject private var model = ServiceManager()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            Image(nsImage: BrandAssets.menuBarIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .accessibilityLabel("CuySearch")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
