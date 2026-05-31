import SwiftUI
import AppKit

@main
struct TunnelMonitorApp: App {
    @NSApplicationDelegateAdaptor(TunnelMonitorAppDelegate.self) private var appDelegate
    @StateObject private var model = MonitorState()
    @StateObject private var login = LoginItem()
    @StateObject private var shell = AppShellController()
    @StateObject private var menuStatus = MenuBarStatusModel()

    var body: some Scene {
        MenuBarExtra(isInserted: menuBarInsertedBinding) {
            MenuBarPopoverView(model: model, login: login, shell: shell)
                .onAppear {
                    TunnelMonitorAppDelegate.sharedShell = shell
                    menuStatus.bind(to: model)
                }
        } label: {
            MenuBarLabelView(status: menuStatus)
                .background(AppWindowOpener(shell: shell))
        }
        .menuBarExtraStyle(.window)

        Window("Tunnel Monitor", id: "dashboard") {
            DashboardView(model: model, login: login, shell: shell)
                .onAppear { TunnelMonitorAppDelegate.sharedShell = shell }
        }
        .defaultSize(width: 440, height: 560)

        Window("Configuration", id: "setup") {
            SetupWizardView(onSaved: { model.reload() })
                .onAppear { TunnelMonitorAppDelegate.sharedShell = shell }
        }
        .defaultSize(width: 520, height: 560)

        Settings {
            SettingsView(shell: shell, model: model)
                .onAppear { TunnelMonitorAppDelegate.sharedShell = shell }
        }
    }

    /// MenuBarExtra writes `isInserted` during layout; avoid re-entrant didSet side effects.
    private var menuBarInsertedBinding: Binding<Bool> {
        Binding(
            get: { shell.showMenuBar },
            set: { shell.updateMenuBarInserted($0) }
        )
    }
}
