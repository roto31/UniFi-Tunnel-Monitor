import SwiftUI
import AppKit

@main
struct TunnelMonitorApp: App {
    @StateObject private var model = MonitorState()
    @StateObject private var login = LoginItem()
    @State private var showSetupWizard = false

    var body: some Scene {
        MenuBarExtra {
            StatusView(model: model, login: login, showSetupWizard: $showSetupWizard)
                .frame(width: 380)
                .sheet(isPresented: $showSetupWizard) {
                    SetupWizardView(onSaved: { model.reload() })
                }
        } label: {
            Image(systemName: model.menuBarSymbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(model.menuBarColor, .secondary)
                .accessibilityLabel("Tunnel Monitor — \(model.alertState)")
        }
        .menuBarExtraStyle(.window)
    }
}
