import AppKit
import SwiftUI
@preconcurrency import UserNotifications

@main
struct StandUpReminderApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = ReminderViewModel()
    @State private var isMenuBarIconVisible = true
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("StandUpReminder", id: "main-window") {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 560, minHeight: 420)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.refreshFromStore()
            }
        }

        MenuBarExtra(isInserted: $isMenuBarIconVisible) {
            MenuBarMenuView()
                .environmentObject(viewModel)
        } label: {
            menuBarIconLabel
        }
        .menuBarExtraStyle(.menu)
    }

    @ViewBuilder
    private var menuBarIconLabel: some View {
        if let icon = preparedMenuBarIcon() {
            Image(nsImage: icon)
        } else {
            Label("Stand", systemImage: "figure.stand")
        }
    }

    private func preparedMenuBarIcon() -> NSImage? {
        guard let originalIcon = NSImage(named: "menubar_icon"),
              let icon = originalIcon.copy() as? NSImage else {
            return nil
        }
        icon.size = NSSize(width: 16, height: 16)
        icon.isTemplate = true
        return icon
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor
    static func presentMainWindow() {
        _ = NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard enforceSingleInstance() else { return }

        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let iconImage = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = iconImage
        }
        UNUserNotificationCenter.current().delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @MainActor
    private func enforceSingleInstance() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return true }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentPID }

        guard !otherInstances.isEmpty else { return true }

        // If a second process is started (for example by LaunchAgent + manual open),
        // keep the existing instance and terminate the duplicate process.
        if let primary = otherInstances.first {
            _ = primary.activate()
        }
        NSApp.terminate(nil)
        return false
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleWindowWillClose() {
        Task { @MainActor in
            DispatchQueue.main.async {
                let hasVisibleWindow = NSApp.windows.contains { window in
                    window.isVisible && !window.isMiniaturized && window.canBecomeMain
                }
                if !hasVisibleWindow {
                    _ = NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppDelegate.presentMainWindow()
        return false
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
        Task { @MainActor in
            AppDelegate.presentMainWindow()
        }
    }
}
