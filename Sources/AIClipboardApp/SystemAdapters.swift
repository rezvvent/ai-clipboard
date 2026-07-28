import AIClipboardCore
import AppKit
import Carbon
import Foundation
import ServiceManagement
import SwiftUI
import Vision

enum ImageCanonicalizer {
    static func canonicalPNG(from data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else { return nil }

        let width = source.width
        let height = source.height
        guard width > 0, height > 0 else { return nil }
        var pixels = Data(count: width * height * 4)
        let rendered: CGImage? = pixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return nil }
            context.interpolationQuality = .none
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        guard let rendered else { return nil }
        return NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:])
    }

    static func canonicalPNG(path: String) -> Data? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return canonicalPNG(from: data)
    }
}

enum PasteboardCaptureResolver {
    static func prefersImage(
        orderedTypes: [NSPasteboard.PasteboardType],
        hasText: Bool
    ) -> Bool {
        let imageTypes: Set<NSPasteboard.PasteboardType> = [.png, .tiff]
        let firstRelevant = orderedTypes.first {
            imageTypes.contains($0) || $0 == .string || $0 == .URL
        }
        // Browsers often attach a favicon or preview image after the URL/text.
        return !hasText || firstRelevant.map(imageTypes.contains) == true
    }
}

enum ScreenshotOCR {
    static func recognize(in data: Data, languages: [String] = ["ru-RU", "en-US"]) async -> String? {
        guard let image = NSImage(data: data) else { return nil }
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let text = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text?.isEmpty == false ? text : nil)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            request.usesLanguageCorrection = true
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try VNImageRequestHandler(cgImage: cgImage).perform([request])
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    enum RegistrationResult: Equatable {
        case enabled
        case requiresApproval
        case disabled
        case failed(String)
    }

    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var isAvailable = true
    @Published var errorMessage: String?

    private let service = SMAppService.mainApp

    init() {
        refresh()
    }

    func ensureEnabledByDefault() {
        guard ProcessInfo.processInfo.environment["AI_CLIPBOARD_DISABLE_AUTORUN"] != "1" else {
            refresh()
            return
        }
        refresh()
        guard service.status == .notRegistered else { return }
        setEnabled(true)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> RegistrationResult {
        errorMessage = nil
        do {
            if enabled {
                if service.status == .notRegistered {
                    try service.register()
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
        if let errorMessage {
            return .failed(errorMessage)
        }
        if requiresApproval {
            return .requiresApproval
        }
        if isEnabled {
            return .enabled
        }
        if !enabled {
            return .disabled
        }
        let languageCode = Locale.current.language.languageCode?.identifier == "ru"
            ? "ru"
            : "en"
        let message = AppLocalization.string(
            Bundle.main.bundleURL.path.contains("/Applications/")
                ? "startup.error.registration"
                : "startup.error.moveToApplications",
            languageCode: languageCode
        )
        errorMessage = message
        return .failed(message)
    }

    func refresh() {
        switch service.status {
        case .enabled:
            isEnabled = true
            requiresApproval = false
            isAvailable = true
        case .requiresApproval:
            isEnabled = false
            requiresApproval = true
            isAvailable = true
        case .notRegistered:
            isEnabled = false
            requiresApproval = false
            isAvailable = true
        case .notFound:
            isEnabled = false
            requiresApproval = false
            isAvailable = false
        @unknown default:
            isEnabled = false
            requiresApproval = false
            isAvailable = false
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class ClipboardMonitor {
    private let pipeline: ClipboardProcessingPipeline
    private var timer: Timer?
    private var settleTimer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    var onProcessedChange: ((PipelineOutcome) -> Void)?

    init(pipeline: ClipboardProcessingPipeline) {
        self.pipeline = pipeline
    }

    func start(interval: TimeInterval = 0.75) {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: max(0.25, interval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        settleTimer?.invalidate()
        settleTimer = nil
    }

    func ignorePasteboardChange(_ changeCount: Int) {
        lastChangeCount = max(lastChangeCount, changeCount)
    }

    private func poll() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChangeCount else { return }
        lastChangeCount = board.changeCount
        scheduleSettledCapture(expectedChangeCount: board.changeCount)
    }

    private func scheduleSettledCapture(expectedChangeCount: Int) {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let current = NSPasteboard.general.changeCount
                guard current == expectedChangeCount else {
                    self.lastChangeCount = current
                    self.scheduleSettledCapture(expectedChangeCount: current)
                    return
                }
                self.captureSettledPasteboard()
            }
        }
        if let settleTimer { RunLoop.main.add(settleTimer, forMode: .common) }
    }

    private func captureSettledPasteboard() {
        let board = NSPasteboard.general
        let frontmost = NSWorkspace.shared.frontmostApplication
        let source = frontmost.map {
            SourceApplication(
                bundleIdentifier: $0.bundleIdentifier ?? "unknown",
                applicationName: $0.localizedName ?? "Unknown",
                applicationPath: $0.bundleURL?.path
            )
        }
        let fileURLs = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let files = fileURLs.prefix(100).map { url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return FileReference(
                path: url.path,
                displayName: url.lastPathComponent,
                size: (attributes?[.size] as? NSNumber)?.int64Value
            )
        }
        let plainText = board.string(forType: .string)
        let richText = board.data(forType: .rtf)
        let rawImage = preferredImageData(from: board, hasText: plainText != nil)
        Task {
            let canonicalImage = rawImage.flatMap(ImageCanonicalizer.canonicalPNG) ?? rawImage
            let recognizedText = if let canonicalImage {
                await ScreenshotOCR.recognize(in: canonicalImage)
            } else {
                Optional<String>.none
            }
            let content = CapturedContent(
                plainText: canonicalImage == nil ? plainText : recognizedText,
                richText: canonicalImage == nil ? richText : nil,
                imageData: canonicalImage,
                fileReferences: files,
                sourceApplication: source
            )
            let outcome = await pipeline.process(content)
            if outcome.disposition == .stored || outcome.disposition == .deduplicated {
                onProcessedChange?(outcome)
            }
        }
    }

    private func preferredImageData(from board: NSPasteboard, hasText: Bool) -> Data? {
        let firstItem = board.pasteboardItems?.first
        let orderedTypes = firstItem?.types ?? board.types ?? []
        guard PasteboardCaptureResolver.prefersImage(
            orderedTypes: orderedTypes,
            hasText: hasText
        ) else { return nil }
        // Read from the selected pasteboard item, not the entire board. This
        // prevents an unrelated image in another item from becoming the capture.
        return firstItem?.data(forType: .png)
            ?? firstItem?.data(forType: .tiff)
            ?? board.data(forType: .png)
            ?? board.data(forType: .tiff)
    }
}

@MainActor
final class PasteController {
    private weak var previousApplication: NSRunningApplication?
    var onPasteboardWrite: ((Int) -> Void)?

    func rememberFrontmostApplication() {
        let current = NSWorkspace.shared.frontmostApplication
        if current?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = current
        }
    }

    func copy(_ item: ClipboardItem, plainText: Bool) {
        let board = NSPasteboard.general
        board.clearContents()
        if !plainText, let imageData = item.imageData, let image = NSImage(data: imageData) {
            board.writeObjects([image])
        } else if !plainText, let imagePath = item.imagePath, let image = NSImage(contentsOfFile: imagePath) {
            board.writeObjects([image])
        } else if !plainText, !item.fileReferences.isEmpty {
            board.writeObjects(item.fileReferences.map { URL(fileURLWithPath: $0.path) } as [NSURL])
        } else if !plainText, let rich = item.richTextData {
            board.setData(rich, forType: .rtf)
            if let text = item.rawText { board.setString(text, forType: .string) }
        } else if let text = item.rawText ?? item.normalizedText {
            board.setString(text, forType: .string)
        }
        onPasteboardWrite?(board.changeCount)
    }

    func restoreFocus() {
        previousApplication?.activate(options: [.activateIgnoringOtherApps])
    }

}

@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let callback: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in owner.callback() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard status == noErr else { return nil }
        let identifier = EventHotKeyID(signature: OSType(0x41494342), id: 1)
        guard RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        ) == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

@MainActor
private enum WindowMotion {
    static func show(_ window: NSWindow) {
        window.center()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
            return
        }

        let targetFrame = window.frame
        let startFrame = targetFrame
            .insetBy(dx: 12, dy: 9)
            .offsetBy(dx: 0, dy: -5)
        window.alphaValue = 0
        window.setFrame(startFrame, display: false)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.2,
                0.75,
                0.25,
                1
            )
            window.animator().alphaValue = 1
            window.animator().setFrame(targetFrame, display: true)
        }
    }

    static func hide(_ window: NSWindow) {
        guard window.isVisible else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.orderOut(nil)
            return
        }
        let originalFrame = window.frame
        let endFrame = originalFrame
            .insetBy(dx: 8, dy: 6)
            .offsetBy(dx: 0, dy: -3)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            window.animator().setFrame(endFrame, display: true)
        } completionHandler: {
            window.orderOut(nil)
            window.alphaValue = 1
            window.setFrame(originalFrame, display: false)
        }
    }
}

@MainActor
final class QuickSearchPanelController: NSWindowController, NSWindowDelegate {
    init(model: AppModel) {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: QuickSearchView(model: model))
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 18
        panel.contentView?.layer?.masksToBounds = true
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        WindowMotion.show(window)
    }

    func dismiss() {
        guard let window else { return }
        WindowMotion.hide(window)
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(model: AppModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "menu.settings")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 480)
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        WindowMotion.show(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        WindowMotion.hide(sender)
        return false
    }
}

@MainActor
final class AccountWindowController: NSWindowController, NSWindowDelegate {
    init(model: AppModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "account.window.title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 540)
        window.contentView = NSHostingView(rootView: AccountWindowView(model: model))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        WindowMotion.show(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        WindowMotion.hide(sender)
        return false
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    init(model: AppModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_140, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "app.name")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1_020, height: 660)
        window.contentView = NSHostingView(rootView: MainWindowView(model: model))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        WindowMotion.show(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        WindowMotion.hide(sender)
        return false
    }
}
