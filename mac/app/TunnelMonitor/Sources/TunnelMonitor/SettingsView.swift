import SwiftUI

struct SettingsView: View {
    @ObservedObject var shell: AppShellController
    @ObservedObject var model: MonitorState

    private let refreshOptions: [(label: String, seconds: Double)] = [
        ("5 seconds", 5),
        ("15 seconds", 15),
        ("30 seconds", 30),
    ]

    var body: some View {
        Form {
            Section("Display surfaces") {
                Toggle("Show menu bar icon", isOn: $shell.showMenuBar)
                Toggle("Show Dock icon", isOn: $shell.showDockIcon)
                Toggle("Open dashboard at launch", isOn: $shell.openDashboardAtLaunch)
                Button("Open Dashboard Now") {
                    shell.openDashboardRequest = true
                }
            }

            Section("Refresh") {
                Picker("Poll state.json every", selection: $shell.refreshIntervalSeconds) {
                    ForEach(refreshOptions, id: \.seconds) { opt in
                        Text(opt.label).tag(opt.seconds)
                    }
                }
                .onChange(of: shell.refreshIntervalSeconds) {
                    model.setRefreshInterval(shell.refreshIntervalSeconds)
                }
            }

            Section("Desktop widget") {
                Toggle("Sync status to App Group for widget", isOn: $shell.widgetSyncEnabled)
                Text("Add the Tunnel Monitor widget from the macOS widget gallery (Notification Center or desktop). Requires macOS 14 Sonoma or later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("State file", value: MonitorPaths.stateFile)
                LabeledContent("LaunchDaemon", value: AppBranding.launchDaemonLabel)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .tmAppWindowBackground()
        .frame(width: 440, height: 360)
    }
}
