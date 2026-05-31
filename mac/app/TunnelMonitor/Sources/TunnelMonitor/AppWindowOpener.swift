import SwiftUI
import AppKit

/// Opens dashboard/setup windows via `openWindow`. Lives on the menu bar label (always loaded).
struct AppWindowOpener: View {
    @ObservedObject var shell: AppShellController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { flushPendingRequests() }
            .onChange(of: shell.openDashboardRequest) { _, requested in
                guard requested else { return }
                openDashboard()
                shell.openDashboardRequest = false
            }
            .onChange(of: shell.openSetupWizardRequest) { _, requested in
                guard requested else { return }
                openSetup()
                shell.clearSetupWizardRequest()
            }
    }

    private func flushPendingRequests() {
        if shell.openSetupWizardRequest {
            openSetup()
            shell.clearSetupWizardRequest()
        }
        if shell.openDashboardRequest {
            openDashboard()
            shell.openDashboardRequest = false
        }
    }

    private func openDashboard() {
        activateApp()
        openWindow(id: "dashboard")
        orderFrontSoon()
    }

    private func openSetup() {
        activateApp()
        openWindow(id: "setup")
        orderFrontSoon()
    }

    private func activateApp() {
        if shell.showDockIcon {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func orderFrontSoon() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
