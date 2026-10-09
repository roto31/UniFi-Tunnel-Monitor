import Foundation
import SwiftUI
import Combine
import AppKit

struct DedupBlock: Decodable, Equatable {
    let reachable: Bool
    let state: String?
    let checked_at: String?
}

struct SpokePolicyBlock: Decodable, Equatable {
    let enabled: Bool?
    let reachable: Bool?
    let state: String?
    let label: String?
    let checked_at: String?
}

struct Snapshot: Decodable, Equatable {
    struct PingCheck: Decodable, Equatable {
        let target: String?
        let ok: Bool?
        let latency_ms: Double?
    }
    struct DNSCheck: Decodable, Equatable {
        let host: String?
        let resolved: String?
        let expected: String?
        let match: Bool?
    }
    struct Checks: Decodable, Equatable {
        let tunnel: PingCheck
        let remote_wan: PingCheck
        let our_internet: PingCheck
        let dns: DNSCheck
    }

    let timestamp: String
    let alert_state: String
    let failure_count: Int
    let checks: Checks
    let dedup: DedupBlock
    let last_alert_sent_at: String?
    let last_recovery_sent_at: String?
    let diagnosis: String
    let down_since: String?
    let spoke_policy: SpokePolicyBlock?
    let remote_wan_observed: String?
    let advisories: [String]

    enum CodingKeys: String, CodingKey {
        case timestamp, alert_state, failure_count, checks
        case udr7_dedup, router_dedup
        case last_alert_sent_at, last_recovery_sent_at, diagnosis, down_since
        case spoke_policy, remote_wan_observed, advisories
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(String.self, forKey: .timestamp)
        alert_state = try c.decode(String.self, forKey: .alert_state)
        failure_count = try c.decode(Int.self, forKey: .failure_count)
        checks = try c.decode(Checks.self, forKey: .checks)
        last_alert_sent_at = try c.decodeIfPresent(String.self, forKey: .last_alert_sent_at)
        last_recovery_sent_at = try c.decodeIfPresent(String.self, forKey: .last_recovery_sent_at)
        diagnosis = try c.decode(String.self, forKey: .diagnosis)
        down_since = try c.decodeIfPresent(String.self, forKey: .down_since)
        spoke_policy = try c.decodeIfPresent(SpokePolicyBlock.self, forKey: .spoke_policy)
        remote_wan_observed = try c.decodeIfPresent(String.self, forKey: .remote_wan_observed)
        advisories = try c.decodeIfPresent([String].self, forKey: .advisories) ?? []

        if let u = try c.decodeIfPresent(DedupBlock.self, forKey: .udr7_dedup) {
            dedup = u
        } else if let r = try c.decodeIfPresent(DedupBlock.self, forKey: .router_dedup) {
            dedup = r
        } else {
            dedup = DedupBlock(reachable: false, state: nil, checked_at: nil)
        }
    }
}

enum MonitorPaths {
    static let stateFile = "/opt/tunnel-monitor/state.json"
    static let logFile   = "/opt/tunnel-monitor/monitor.log"
    static let config    = "/opt/tunnel-monitor/config.env"
    static let installDir = "/opt/tunnel-monitor"
}

private struct ReloadPayload {
    let snapshot: Snapshot?
    let error: String?
    let presentation: StatusPresentation
    let widgetSnapshot: WidgetStatusSnapshot?
}

@MainActor
final class MonitorState: ObservableObject {

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var lastLoadError: String?
    @Published private(set) var lastReadAt: Date = .distantPast
    @Published private(set) var presentation: StatusPresentation = .unavailable(error: nil)

    private var timer: Timer?
    private var refreshInterval: TimeInterval = AppPreferences.refreshIntervalSeconds
    private var reloadInFlight = false

    init() {
        reload()
        restartTimer()
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        refreshInterval = max(5, interval)
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        guard !reloadInFlight else { return }
        reloadInFlight = true
        let statePath = MonitorPaths.stateFile
        let syncWidget = AppPreferences.widgetSyncEnabled

        Task.detached(priority: .utility) {
            let payload = Self.loadPayload(from: statePath, syncWidget: syncWidget)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.apply(payload)
                self.reloadInFlight = false
            }
        }
    }

    private func apply(_ payload: ReloadPayload) {
        if snapshot != payload.snapshot { snapshot = payload.snapshot }
        if lastLoadError != payload.error { lastLoadError = payload.error }
        if presentation != payload.presentation { presentation = payload.presentation }
        lastReadAt = Date()
        if let widget = payload.widgetSnapshot {
            AppGroupSync.writeWidgetSnapshot(widget)
        }
    }

    nonisolated private static func loadPayload(from path: String, syncWidget: Bool) -> ReloadPayload {
        let url = URL(fileURLWithPath: path)
        do {
            let data = try Data(contentsOf: url, options: [.uncached, .mappedIfSafe])
            let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
            let presentation = StatusPresentation.from(snapshot: decoded)
            let widget: WidgetStatusSnapshot? = syncWidget
                ? WidgetStatusSnapshot.from(presentation: presentation, lastCheck: decoded.timestamp)
                : nil
            return ReloadPayload(snapshot: decoded, error: nil, presentation: presentation, widgetSnapshot: widget)
        } catch {
            let presentation = StatusPresentation.unavailable(error: error.localizedDescription)
            return ReloadPayload(snapshot: nil, error: error.localizedDescription, presentation: presentation, widgetSnapshot: nil)
        }
    }

    var alertState: String { snapshot?.alert_state ?? "UNKNOWN" }
    var diagnosis: String  { snapshot?.diagnosis ?? "NO_STATE_FILE" }
    var trafficLight: TrafficLight { presentation.trafficLight }

    var menuBarColor: Color { trafficLight.color }
}
