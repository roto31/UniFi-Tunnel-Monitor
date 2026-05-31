import SwiftUI

enum StatusSurface {
    case menuBar
    case dashboard
}

struct StatusContentView: View {
    @ObservedObject var model: MonitorState
    @ObservedObject var login: LoginItem
    let surface: StatusSurface
    var showActions: Bool = true
    var showFooter: Bool = true
    var shell: AppShellController?
    @State private var lastActionResult: String?
    @State private var showingActionResult = false

    init(
        model: MonitorState,
        login: LoginItem,
        surface: StatusSurface,
        shell: AppShellController? = nil,
        showActions: Bool = true,
        showFooter: Bool = true
    ) {
        self.model = model
        self.login = login
        self.surface = surface
        self.shell = shell
        self.showActions = showActions
        self.showFooter = showFooter
    }

    var body: some View {
        TMSectionContainer {
            statusHeader
            if !model.presentation.issues.isEmpty {
                issuesSection
            }
            checksSection
            dedupSection
            if showActions {
                actionsSection
            }
            if let result = lastActionResult, surface == .menuBar {
                Text(result)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal, 4)
            }
            if showFooter {
                footer
            }
        }
        .padding(14)
        .tmAppWindowBackground()
        .modifier(ActionResultAlertModifier(
            surface: surface,
            isPresented: $showingActionResult,
            message: lastActionResult
        ))
    }

    private var statusHeader: some View {
        let p = model.presentation
        return HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(p.trafficLight.color)
                .frame(width: 16, height: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(p.trafficLight.title)
                    .font(.headline)
                Text(p.reasonText)
                    .font(.subheadline)
                    .foregroundStyle(p.trafficLight.color)
                if let down = p.downDurationText {
                    Text(down)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let ts = model.snapshot?.timestamp {
                    Text("Last check: \(ts)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let err = model.lastLoadError {
                    Text("state.json unreadable: \(err)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            Text(model.alertState)
                .font(.caption.weight(.bold))
                .foregroundStyle(p.trafficLight.color)
                .tmGlassBadge(tint: p.trafficLight.color)
        }
        .tmGlassCard(tint: p.trafficLight.color)
    }

    private var issuesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Issues").font(.subheadline).bold()
            ForEach(model.presentation.issues) { issue in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(issue.severity.color)
                        .frame(width: 8, height: 8)
                        .padding(.top, 4)
                    Text(issue.message)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tmGlassCard(tint: .yellow)
    }

    @ViewBuilder
    private var checksSection: some View {
        Group {
            if let s = model.snapshot {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Checks").font(.subheadline).bold()
                    CheckRow(label: "Tunnel",
                             target: s.checks.tunnel.target,
                             ok: s.checks.tunnel.ok,
                             latency: s.checks.tunnel.latency_ms)
                    CheckRow(label: "Remote WAN",
                             target: s.checks.remote_wan.target,
                             ok: s.checks.remote_wan.ok,
                             latency: s.checks.remote_wan.latency_ms)
                    CheckRow(label: "Our internet",
                             target: s.checks.our_internet.target,
                             ok: s.checks.our_internet.ok,
                             latency: s.checks.our_internet.latency_ms)
                    dnsRow(s.checks.dns)
                    Text("Failure count: \(s.failure_count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No state.json").font(.subheadline).bold()
                    Text("The daemon may not have run yet. Try Force Check.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .tmGlassCard()
    }

    private func dnsRow(_ dns: Snapshot.DNSCheck) -> some View {
        let ok = dns.match ?? false
        let host = dns.host ?? "?"
        let resolved = dns.resolved ?? "<none>"
        let expected = dns.expected ?? "?"
        let detail = ok
            ? "matches \(expected)"
            : "\(resolved) ≠ \(expected)"
        return HStack(spacing: 6) {
            Circle()
                .fill(ok ? .green : .red)
                .frame(width: 8, height: 8)
            Text("DNS").frame(width: 90, alignment: .leading)
            Text("\(host): \(detail)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
    }

    @ViewBuilder
    private var dedupSection: some View {
        if let s = model.snapshot {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppBranding.dedupSectionTitle).font(.subheadline).bold()
                HStack(spacing: 6) {
                    Circle()
                        .fill(s.dedup.reachable ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(s.dedup.reachable
                         ? "Reachable: \(s.dedup.state ?? "—")"
                         : "Unreachable")
                    .font(.caption)
                    Spacer()
                }
            }
            .tmGlassCard(tint: s.dedup.reachable ? .green : .red)
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions").font(.subheadline).bold()
            HStack(spacing: 8) {
                Button(action: openSetup) {
                    Label("Setup…", systemImage: "gearshape")
                }
                .tmGlassActionButton()
                Button { runAction { Actions.checkNow() } } label: {
                    Label("Force Check", systemImage: "arrow.clockwise")
                }
                .tmGlassActionButton()
                Button { runAction { Actions.testNotify() } } label: {
                    Label("Test Notify", systemImage: "bell.badge")
                }
                .tmGlassActionButton()
                Button { runAction { Actions.testEmail() } } label: {
                    Label("Test Email", systemImage: "envelope")
                }
                .tmGlassActionButton()
            }
            HStack(spacing: 8) {
                Button { runAction { Actions.tailLog() } } label: {
                    Label("Tail Log", systemImage: "text.alignleft")
                }
                .tmGlassActionButton()
                Button { runAction { Actions.editConfig() } } label: {
                    Label("Edit Config", systemImage: "slider.horizontal.3")
                }
                .tmGlassActionButton()
                Button { runAction { Actions.sshTest() } } label: {
                    Label("SSH Test", systemImage: "key")
                }
                .tmGlassActionButton()
            }
            HStack(spacing: 8) {
                Button { runAction { Actions.resetState() } } label: {
                    Label("Reset State", systemImage: "arrow.counterclockwise")
                }
                .tmGlassActionButton()
                Button { runMainActorAction { Actions.copySSHPubkeyCommand() } } label: {
                    Label("Copy SSH Auth Cmd", systemImage: "doc.on.clipboard")
                }
                .tmGlassActionButton()
                Button { runMainActorAction { Actions.openStateInFinder(); return "Revealed state.json in Finder." } } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .tmGlassActionButton()
            }
        }
        .tmGlassCard()
    }

    private var footer: some View {
        HStack {
            Toggle(isOn: Binding(get: { login.isEnabled },
                                 set: { _ in login.toggle() })) {
                Text("Launch at login")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            if let err = login.lastError {
                Text(err).font(.caption2).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .tmGlassActionButton()
            .applyMenuBarQuitShortcut(surface == .dashboard)
        }
        .tmGlassCard()
    }

    private func openSetup() {
        shell?.requestSetupWizard()
    }

    private func runAction(_ block: @escaping @Sendable () -> String) {
        Task.detached {
            let result = block()
            await MainActor.run {
                lastActionResult = result
                if surface == .dashboard {
                    showingActionResult = true
                }
                model.reload()
            }
        }
    }

    private func runMainActorAction(_ block: @MainActor @escaping () -> String) {
        Task { @MainActor in
            let result = block()
            lastActionResult = result
            if surface == .dashboard {
                showingActionResult = true
            }
        }
    }
}

private struct ActionResultAlertModifier: ViewModifier {
    let surface: StatusSurface
    @Binding var isPresented: Bool
    let message: String?

    func body(content: Content) -> some View {
        if surface == .dashboard {
            content.alert("Result", isPresented: $isPresented, presenting: message) { _ in
                Button("OK", role: .cancel) {}
            } message: { result in
                Text(result)
            }
        } else {
            content
        }
    }
}

private extension View {
    @ViewBuilder
    func applyMenuBarQuitShortcut(_ enabled: Bool) -> some View {
        if enabled {
            keyboardShortcut("q")
        } else {
            self
        }
    }
}

private struct CheckRow: View {
    let label: String
    let target: String?
    let ok: Bool?
    let latency: Double?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label).frame(width: 90, alignment: .leading)
            Text(detail)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private var color: Color {
        switch ok {
        case .some(true):  return .green
        case .some(false): return .red
        default:           return .gray
        }
    }

    private var detail: String {
        let t = target ?? "—"
        switch ok {
        case .some(true):
            if let l = latency {
                return "\(t)  \(Int(l)) ms"
            }
            return "\(t)  OK"
        case .some(false):
            return "\(t)  FAIL"
        default:
            return "\(t)  pending"
        }
    }
}
