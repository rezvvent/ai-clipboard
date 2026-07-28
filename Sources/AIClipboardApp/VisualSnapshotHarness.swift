#if DEBUG
import AppKit
import Foundation

@MainActor
enum VisualSnapshotHarness {
    static func captureIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["AI_CLIPBOARD_SNAPSHOT_PATH"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let screen = ProcessInfo.processInfo.environment["AI_CLIPBOARD_SNAPSHOT_SCREEN"]
            let target: NSWindow?
            if screen == "quick" {
                target = NSApp.windows.first(where: { $0.isVisible && $0.level == .floating })
            } else if screen == "account" {
                target = NSApp.windows.first(where: {
                    $0.isVisible && $0.frame.width >= 750 && $0.frame.width < 850
                })
            } else if screen == "settings" {
                target = NSApp.windows.first(where: {
                    $0.isVisible && $0.frame.width >= 680 && $0.frame.width < 850
                })
            } else if screen == "autorun" {
                target = NSApp.windows.first(where: {
                    $0.isVisible && $0.sheetParent != nil
                }) ?? NSApp.keyWindow
            } else {
                target = NSApp.windows.first(where: { $0.isVisible && $0.level == .normal })
            }
            guard let window = target else {
                NSApp.terminate(nil)
                return
            }
            let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                CGWindowID(window.windowNumber),
                [.bestResolution, .boundsIgnoreFraming]
            )
            if let image,
               let data = NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            NSApp.terminate(nil)
        }
    }
}
#endif
