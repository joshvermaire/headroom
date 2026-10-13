import AppKit
import HeadroomCore
import SwiftUI

@main
struct HeadroomApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        model.start()
        _model = State(initialValue: model)
        if CommandLine.arguments.contains("--debug-window") || CommandLine.arguments.contains("--debug-snapshot") {
            DebugWindow.show(model: model)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let fraction = model.volume?.availableFraction ?? 0
        HStack(spacing: 4) {
            Image(nsImage: CapacityGlyph.image(fraction: fraction, low: model.isLow))
            switch model.menuBarStyle {
            case .percent: Text(Format.percent(fraction))
            case .bytes: Text(model.volume.map { Format.bytes($0.available) } ?? "–")
            case .icon: EmptyView()
            }
        }
        .accessibilityLabel(model.volume.map { "\(Format.bytes($0.available)) available" } ?? "Headroom")
    }
}

/// A small upright capsule filled from the bottom by the fraction of the disk still available.
/// Template (follows the menu bar's color) normally; orange when below the alert threshold.
enum CapacityGlyph {
    static func image(fraction: Double, low: Bool) -> NSImage {
        let size = NSSize(width: 9, height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            let color: NSColor = low ? .systemOrange : .black
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 2.25, yRadius: 2.25)
            outline.lineWidth = 1.5
            color.setStroke()
            outline.stroke()
            let inner = rect.insetBy(dx: 2.25, dy: 2.25)
            // Always show a sliver so "almost full" doesn't read as "empty glyph".
            let height = max(1, inner.height * min(1, max(0, fraction)))
            color.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: height),
                xRadius: 0.75, yRadius: 0.75
            ).fill()
            return true
        }
        image.isTemplate = !low
        return image
    }
}

/// Debugging aids that don't need screen-recording permission:
///
///   Headroom --debug-window                      also show the panel in a normal window
///   Headroom --debug-snapshot out.png [--page settings|nodeModules]
///                                                render the panel to a PNG after the first scan, then quit
@MainActor
enum DebugWindow {
    static var window: NSWindow?

    static func show(model: AppModel) {
        let args = CommandLine.arguments
        let page: Page = switch args.value(after: "--page") {
        case "settings": .settings
        case "nodeModules": .nodeModules
        default: .main
        }
        let host = NSHostingView(rootView: PanelView(page: page)
            .environment(model)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame.size = host.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.title = "Headroom"
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        guard let output = args.value(after: "--debug-snapshot") else { return }
        Task { @MainActor in
            while model.scanning || model.lastScan == nil {
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: .seconds(1))
            let size = host.fittingSize
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
            exit(0)
        }
    }
}

private extension Array where Element == String {
    func value(after flag: String) -> String? {
        guard let i = firstIndex(of: flag), indices.contains(i + 1) else { return nil }
        return self[i + 1]
    }
}
