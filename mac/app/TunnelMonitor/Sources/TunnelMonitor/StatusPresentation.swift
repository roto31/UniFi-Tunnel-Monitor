import Foundation
import SwiftUI

enum TrafficLight: String, Codable, Equatable {
    case green
    case yellow
    case red

    var color: Color {
        switch self {
        case .green:  return .green
        case .yellow: return .yellow
        case .red:    return .red
        }
    }

    var title: String {
        switch self {
        case .green:  return "Tunnel UP"
        case .yellow: return "Issues detected"
        case .red:    return "Tunnel DOWN"
        }
    }
}

struct StatusIssue: Identifiable, Equatable, Codable {
    let id: String
    let message: String
    let severity: TrafficLight
}

struct StatusPresentation: Equatable {
    let trafficLight: TrafficLight
    let reasonText: String
    let issues: [StatusIssue]
    let downDurationText: String?
    let failureCount: Int
    let alertState: String

    static func unavailable(error: String?) -> StatusPresentation {
        let detail = error ?? "Monitor state unavailable"
        return StatusPresentation(
            trafficLight: .yellow,
            reasonText: detail,
            issues: [StatusIssue(id: "no_state", message: detail, severity: .yellow)],
            downDurationText: nil,
            failureCount: 0,
            alertState: "UNKNOWN"
        )
    }

    static func from(snapshot: Snapshot) -> StatusPresentation {
        let light = computeTrafficLight(snapshot: snapshot)
        let issues = buildIssues(snapshot: snapshot, trafficLight: light)
        let reason = humanDiagnosis(snapshot.diagnosis)
        let downText = downDurationText(for: snapshot)

        return StatusPresentation(
            trafficLight: light,
            reasonText: reason,
            issues: issues,
            downDurationText: snapshot.diagnosis == "HEALTHY" ? nil : downText,
            failureCount: snapshot.failure_count,
            alertState: snapshot.alert_state
        )
    }

    private static func computeTrafficLight(snapshot: Snapshot) -> TrafficLight {
        if snapshot.alert_state == "DOWN" {
            return .red
        }
        if snapshot.diagnosis == "HEALTHY" && snapshot.failure_count == 0 {
            if !snapshot.advisories.isEmpty {
                return .yellow
            }
            return .green
        }
        if snapshot.diagnosis != "HEALTHY" || snapshot.failure_count > 0 {
            return .yellow
        }
        return .green
    }

    private static func buildIssues(snapshot: Snapshot, trafficLight: TrafficLight) -> [StatusIssue] {
        var list: [StatusIssue] = []
        let sev = trafficLight == .red ? TrafficLight.red : TrafficLight.yellow

        if snapshot.checks.tunnel.ok == false {
            let t = snapshot.checks.tunnel.target ?? "remote LAN"
            list.append(StatusIssue(id: "tunnel", message: "Tunnel unreachable (\(t))", severity: sev))
        }
        if snapshot.checks.remote_wan.ok == false {
            let t = snapshot.checks.remote_wan.target ?? "remote WAN"
            list.append(StatusIssue(id: "remote_wan", message: "Remote internet down (\(t))", severity: sev))
        }
        if snapshot.checks.our_internet.ok == false {
            list.append(StatusIssue(id: "our_internet", message: "Local internet down (1.1.1.1)", severity: sev))
        }
        if snapshot.checks.dns.match == false {
            let host = snapshot.checks.dns.host ?? "DDNS"
            let resolved = snapshot.checks.dns.resolved ?? "none"
            let expected = snapshot.checks.dns.expected ?? "?"
            list.append(StatusIssue(
                id: "dns",
                message: "DDNS drift — \(host) resolves to \(resolved), expected \(expected)",
                severity: sev
            ))
        }
        if !snapshot.dedup.reachable {
            list.append(StatusIssue(
                id: "dedup_unreachable",
                message: "\(AppBranding.dedupSectionTitle): gateway unreachable",
                severity: .yellow
            ))
        } else if let state = snapshot.dedup.state, state.hasSuffix(":DOWN") {
            list.append(StatusIssue(
                id: "dedup_down",
                message: "\(AppBranding.dedupSectionTitle): \(state)",
                severity: sev
            ))
        }

        if snapshot.diagnosis != "HEALTHY" && snapshot.diagnosis != "TUNNEL_DOWN" {
            let msg = diagnosisIssueMessage(snapshot.diagnosis)
            if !list.contains(where: { $0.message == msg }) {
                list.append(StatusIssue(id: "diagnosis_\(snapshot.diagnosis)", message: msg, severity: sev))
            }
        } else if snapshot.diagnosis == "TUNNEL_DOWN" && list.isEmpty {
            list.append(StatusIssue(id: "tunnel_down", message: "Tunnel down — remote WAN and DDNS OK", severity: sev))
        }

        list.append(contentsOf: advisoryIssues(snapshot))

        if snapshot.failure_count > 0 && snapshot.alert_state == "UP" {
            list.append(StatusIssue(
                id: "failures",
                message: "Failure count \(snapshot.failure_count) (alert after threshold)",
                severity: .yellow
            ))
        }

        return list
    }

    private static func humanDiagnosis(_ code: String) -> String {
        switch code {
        case "HEALTHY":              return "HEALTHY"
        case "TUNNEL_DOWN":          return "TUNNEL DOWN"
        case "DDNS_DRIFT":           return "DDNS DRIFT — fix No-IP record"
        case "REMOTE_INTERNET_DOWN": return "REMOTE INTERNET DOWN"
        case "OUR_INTERNET_DOWN":    return "OUR INTERNET DOWN (no alert)"
        case "UDR7_UNREACHABLE", "ROUTER_UNREACHABLE":
            return "\(AppBranding.routerShortName) UNREACHABLE — Mac taking over"
        case "DISAGREEMENT":         return "DISAGREEMENT (\(AppBranding.routerShortName) says UP)"
        default:                     return code
        }
    }

    private static func diagnosisIssueMessage(_ code: String) -> String {
        humanDiagnosis(code)
    }

    private static func advisoryIssues(_ snapshot: Snapshot) -> [StatusIssue] {
        let trimmed = snapshot.spoke_policy?.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmed.isEmpty ? AppBranding.spokePolicySectionTitle : trimmed
        let observed = snapshot.remote_wan_observed ?? "unknown"
        return snapshot.advisories.map { code in
            let message: String
            let severity: TrafficLight
            switch code {
            case "SPOKE_POLICY_DOWN":
                message = "\(title): traffic is not using the tunnel (policy route broken on the spoke)"
                severity = .red
            case "SPOKE_POLICY_DEGRADED":
                message = "\(title): recovering (recent failures, currently up)"
                severity = .yellow
            case "SPOKE_POLICY_MISSING":
                message = "\(title): not installed on the spoke"
                severity = .yellow
            case "SPOKE_UNREACHABLE":
                message = "Spoke unreachable — policy route was not checked"
                severity = .red
            case "REMOTE_WAN_IP_STALE":
                message = "Remote WAN observed \(observed) — update REMOTE_WAN_IP / No-IP"
                severity = .yellow
            case "REMOTE_DDNS_STALE":
                message = "Remote WAN observed \(observed) does not match DDNS — update No-IP"
                severity = .yellow
            default:
                message = code
                severity = .yellow
            }
            return StatusIssue(id: "advisory_\(code)", message: message, severity: severity)
        }
    }

    private static func downDurationText(for snapshot: Snapshot) -> String? {
        if let since = snapshot.down_since, let start = parseISO8601(since) {
            return formatDuration(from: start, to: Date())
        }
        if let alertAt = snapshot.last_alert_sent_at, let start = parseISO8601(alertAt) {
            return formatDuration(from: start, to: Date())
        }
        if snapshot.failure_count > 0 {
            let seconds = snapshot.failure_count * 300
            return formatDuration(seconds: seconds)
        }
        return nil
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        return f2.date(from: s)
    }

    private static func formatDuration(from start: Date, to end: Date) -> String {
        formatDuration(seconds: max(0, Int(end.timeIntervalSince(start))))
    }

    private static func formatDuration(seconds: Int) -> String {
        if seconds < 60 { return "Down for \(seconds)s" }
        let m = seconds / 60
        if m < 60 { return "Down for \(m)m" }
        let h = m / 60
        let rm = m % 60
        if h < 24 { return rm > 0 ? "Down for \(h)h \(rm)m" : "Down for \(h)h" }
        let d = h / 24
        let rh = h % 24
        return rh > 0 ? "Down for \(d)d \(rh)h" : "Down for \(d)d"
    }
}

/// Compact payload written to App Group for the desktop widget.
struct WidgetStatusSnapshot: Codable, Equatable {
    let trafficLight: String
    let reason: String
    let issues: [String]
    let downDurationText: String?
    let lastCheck: String

    static func from(presentation: StatusPresentation, lastCheck: String) -> WidgetStatusSnapshot {
        WidgetStatusSnapshot(
            trafficLight: presentation.trafficLight.rawValue,
            reason: presentation.reasonText,
            issues: presentation.issues.map(\.message),
            downDurationText: presentation.downDurationText,
            lastCheck: lastCheck
        )
    }
}
