import AppKit

@MainActor
final class TunnelMonitorAppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedShell: AppShellController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.sharedShell?.applyActivationPolicy()
        hideDashboardWindowsUnlessRequested()
        let openAtLaunch = AppPreferences.openDashboardAtLaunch
        let firstLaunch = !AppPreferences.hasShownIntroWindow
        guard openAtLaunch || firstLaunch else { return }
        if firstLaunch { AppPreferences.hasShownIntroWindow = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if !SetupWizardState.hasCompleted {
                Self.sharedShell?.requestSetupWizard()
            } else {
                Self.sharedShell?.openDashboardRequest = true
            }
        }
    }

    private func hideDashboardWindowsUnlessRequested() {
        for window in NSApp.windows where window.title == "Tunnel Monitor" || window.title == "Configuration" {
            window.orderOut(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Self.sharedShell?.openDashboardRequest = true
        }
        return true
    }
}
