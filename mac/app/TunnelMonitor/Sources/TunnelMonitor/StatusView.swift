import SwiftUI
import AppKit

struct StatusView: View {
    @ObservedObject var model: MonitorState
    @ObservedObject var login: LoginItem
    @Binding var showSetupWizard: Bool
    @State private var lastActionResult: String?
    @State private var showingActionResult = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            checksSection
            Divider()
            dedupSection
            Divider()
            actionsSection
            Divider()
            footer
        }
        .padding(14)
        .alert("Result", isPresented: $showingActionResult, presenting: lastActionResult) { _ in
            Button("OK", role: .cancel) {}
        } message: { result in
            Text(result)
        }
        .onAppear {
            guard !SetupWizardState.hasCompleted else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                showSetupWizard = true
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: model.menuBarSymbol)
                .font(.title2)
                .foregroundStyle(model.menuBarColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppBranding.statusBannerTitle)
                    .font(.headline)
                Text(model.diagnosis)
                    .font(.subheadline)
                    .foregroundStyle(model.headerColor)
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
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(model.menuBarColor.opacity(0.18))
                .foregroundStyle(model.menuBarColor)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var checksSection: some View {
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
                .lineLimit(1)
                .truncationMode(.middle)
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
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions").font(.subheadline).bold()
            HStack(spacing: 8) {
                Button { showSetupWizard = true } label: {
                    Label("Setup…", systemImage: "gearshape")
                }
                Button { runAction { Actions.checkNow() } } label: {
                    Label("Force Check", systemImage: "arrow.clockwise")
                }
                Button { runAction { Actions.testNotify() } } label: {
                    Label("Test Notify", systemImage: "bell.badge")
                }
                Button { runAction { Actions.testEmail() } } label: {
                    Label("Test Email", systemImage: "envelope")
                }
            }
            HStack(spacing: 8) {
                Button { Actions.tailLog() } label: {
                    Label("Tail Log", systemImage: "text.alignleft")
                }
                Button { Actions.editConfig() } label: {
                    Label("Edit Config", systemImage: "slider.horizontal.3")
                }
                Button { runAction { Actions.sshTest() } } label: {
                    Label("SSH Test", systemImage: "key")
                }
            }
            HStack(spacing: 8) {
                Button { runAction { Actions.resetState() } } label: {
                    Label("Reset State", systemImage: "arrow.counterclockwise")
                }
                Button {
                    lastActionResult = Actions.copySSHPubkeyCommand()
                    showingActionResult = true
                } label: {
                    Label("Copy SSH Auth Cmd", systemImage: "doc.on.clipboard")
                }
                Button { Actions.openStateInFinder() } label: {
                    Label("Reveal", systemImage: "folder")
                }
            }
        }
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
            .keyboardShortcut("q")
        }
    }

    private func runAction(_ block: @escaping () -> String) {
        Task.detached {
            let result = block()
            await MainActor.run {
                lastActionResult = result
                showingActionResult = true
                model.reload()
            }
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
