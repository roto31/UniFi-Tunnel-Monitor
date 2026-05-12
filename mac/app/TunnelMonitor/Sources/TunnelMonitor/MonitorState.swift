import Foundation
import SwiftUI
import Combine

struct DedupBlock: Decodable, Equatable {
    let reachable: Bool
    let state: String?
    let checked_at: String?
}

struct Snapshot: Decodable {
    struct PingCheck: Decodable {
        let target: String?
        let ok: Bool?
        let latency_ms: Double?
    }
    struct DNSCheck: Decodable {
        let host: String?
        let resolved: String?
        let expected: String?
        let match: Bool?
    }
    struct Checks: Decodable {
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

    enum CodingKeys: String, CodingKey {
        case timestamp, alert_state, failure_count, checks
        case udr7_dedup, router_dedup
        case last_alert_sent_at, last_recovery_sent_at, diagnosis
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

@MainActor
final class MonitorState: ObservableObject {

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var lastLoadError: String?
    @Published private(set) var lastReadAt: Date = .distantPast

    private var timer: Timer?

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        let url = URL(fileURLWithPath: MonitorPaths.stateFile)
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
            snapshot = decoded
            lastLoadError = nil
            lastReadAt = Date()
        } catch {
            snapshot = nil
            lastLoadError = error.localizedDescription
            lastReadAt = Date()
        }
    }

    var alertState: String { snapshot?.alert_state ?? "UNKNOWN" }
    var diagnosis: String  { snapshot?.diagnosis ?? "NO_STATE_FILE" }

    var menuBarSymbol: String {
        switch alertState {
        case "UP":   return "lock.shield.fill"
        case "DOWN": return "exclamationmark.shield.fill"
        default:     return "questionmark.diamond.fill"
        }
    }

    var menuBarColor: Color {
        switch alertState {
        case "UP":   return .green
        case "DOWN": return .red
        default:     return .yellow
        }
    }

    var headerColor: Color { menuBarColor }
}
