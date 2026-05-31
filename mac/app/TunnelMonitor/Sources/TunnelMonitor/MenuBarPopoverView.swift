import SwiftUI

/// Menu bar popover content — no sheets or alerts (those crash under MenuBarExtra window style).
struct MenuBarPopoverView: View {
    @ObservedObject var model: MonitorState
    @ObservedObject var login: LoginItem
    @ObservedObject var shell: AppShellController

    var body: some View {
        StatusContentView(
            model: model,
            login: login,
            surface: .menuBar,
            shell: shell
        )
        .frame(width: 400)
    }
}
