import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: MonitorState
    @ObservedObject var login: LoginItem
    @ObservedObject var shell: AppShellController

    var body: some View {
        StatusContentView(
            model: model,
            login: login,
            surface: .dashboard,
            shell: shell
        )
        .frame(minWidth: 420, minHeight: 520)
        .navigationTitle(AppBranding.statusBannerTitle)
        .onAppear {
            if !SetupWizardState.hasCompleted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    shell.requestSetupWizard()
                }
            }
        }
    }
}
