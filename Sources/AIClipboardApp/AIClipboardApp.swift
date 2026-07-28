import AIClipboardCore
import AppKit
import ServiceManagement
import SwiftUI

@main
struct AIClipboardDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    private let model: AppModel?
    private let startupError: String?

    init() {
        do {
            model = try AppModel()
            startupError = nil
        } catch {
            model = nil
            startupError = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup(String(localized: "app.name"), id: "main") {
            if let model {
                MainWindowView(model: model)
                    .frame(minWidth: 1_020, minHeight: 660)
                    .background {
                        MainWindowAccessor { window in
                            appDelegate.registerMainWindow(window)
                        }
                    }
                    .onAppear {
                        NSApp.setActivationPolicy(.regular)
                        appDelegate.configure(model: model)
                        model.start()
#if DEBUG
                        if ProcessInfo.processInfo.environment["AI_CLIPBOARD_SNAPSHOT_SCREEN"] == "quick" {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                model.showQuickSearch()
                            }
                        } else if ProcessInfo.processInfo.environment["AI_CLIPBOARD_SNAPSHOT_SCREEN"] == "settings" {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                model.showSettings()
                            }
                        } else if ProcessInfo.processInfo.environment["AI_CLIPBOARD_SNAPSHOT_SCREEN"] == "account" {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                model.showAccount()
                            }
                        } else if ProcessInfo.processInfo.environment["AI_CLIPBOARD_SNAPSHOT_SCREEN"] == "ai" {
                            model.selectedSection = .ai
                        } else if ProcessInfo.processInfo.environment["AI_CLIPBOARD_SNAPSHOT_SCREEN"] == "autorun" {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                model.autorunPromptPresented = true
                            }
                        } else if ProcessInfo.processInfo.environment["AI_CLIPBOARD_CLOSE_TEST"] == "1" {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                NSApp.mainWindow?.close()
                            }
                        }
                        VisualSnapshotHarness.captureIfRequested()
#endif
                    }
                    .modifier(FirstRunSheetPresenter(model: model))
            } else {
                StorageRecoveryView(detail: startupError ?? String(localized: "storage.error"))
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            if let model {
                CommandMenu(String(localized: "menu.clipboard")) {
                    Button(String(localized: "menu.quickSearch")) { model.showQuickSearch() }
                    Button(model.isPaused ? String(localized: "menu.resume") : String(localized: "menu.pause")) {
                        model.setPause(model.isPaused ? nil : 15 * 60)
                    }
                    Divider()
                    Button(String(localized: "menu.exportJSON")) { model.exportJSON() }
                }
            }
        }

        MenuBarExtra {
            if let model {
                MenuBarContent(model: model)
            } else {
                Button("menu.open") {
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("menu.quit") { NSApp.terminate(nil) }
            }
        } label: {
            Image(systemName: model?.isPaused == true ? "pause.circle.fill" : "clipboard")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            if let model {
                SettingsView(model: model)
                    .frame(width: 720, height: 520)
            } else {
                StorageRecoveryView(detail: startupError ?? String(localized: "storage.error"))
                    .frame(width: 520, height: 340)
            }
        }
    }
}

private struct FirstRunSheetPresenter: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: {
                model.autorunPromptPresented || !model.onboardingCompleted
            },
            set: { presented in
                guard !presented else { return }
                if model.autorunPromptPresented {
                    model.finishAutorunPrompt(enable: false)
                } else if !model.onboardingCompleted {
                    model.completeOnboarding()
                }
            }
        )) {
            if model.autorunPromptPresented {
                AutorunPromptView(model: model)
            } else {
                OnboardingView(model: model)
            }
        }
    }
}

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    @MainActor private weak var model: AppModel?
    @MainActor private weak var mainWindow: NSWindow?
    @MainActor private var recoveryWindow: MainWindowController?

    @MainActor
    func configure(model: AppModel) {
        self.model = model
    }

    @MainActor
    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let backgroundLoginLaunch = !NSApp.isActive && SMAppService.mainApp.status == .enabled
        if backgroundLoginLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.windows
                    .filter { $0.level == .normal }
                    .forEach { $0.orderOut(nil) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        Task { @MainActor in
            if let mainWindow {
                mainWindow.makeKeyAndOrderFront(nil)
            } else if let model {
                let controller = recoveryWindow ?? MainWindowController(model: model)
                recoveryWindow = controller
                controller.show()
            }
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }
}

private struct MainWindowAccessor: NSViewRepresentable {
    let resolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        resolveWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        resolveWindow(for: nsView)
    }

    private func resolveWindow(for view: NSView) {
        DispatchQueue.main.async {
            if let window = view.window {
                resolve(window)
            }
        }
    }
}

struct StorageRecoveryView: View {
    let detail: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("storage.recovery.title")
                .font(.title2.weight(.semibold))
            Text("storage.recovery.description")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("storage.recovery.openFolder") {
                    let folder = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Application Support/AIClipboard")
                    NSWorkspace.shared.open(folder)
                }
                Button("menu.quit") { NSApp.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(minWidth: 520, minHeight: 340)
    }
}
