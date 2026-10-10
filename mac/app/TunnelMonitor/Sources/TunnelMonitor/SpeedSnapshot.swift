import Foundation

/// Result of the optional speed check (`speed.json`, written by the root daemon beside `state.json`).
/// Speed data is informational only: it never feeds `StatusPresentation`, `lastLoadError` or the widget.
struct SpeedSnapshot: Decodable, Equatable {
    let measured_at: String
    let method: String
    let down_mbps: Double?
    let up_mbps: Double?
    let rtt_ms: Double?
    let jitter_ms: Double?
    let loss_pct: Double?
    let ok: Bool
    let error: String?

    static let staleAfterSeconds: TimeInterval = 12 * 60 * 60

    var measuredDate: Date? {
        ISO8601DateFormatter().date(from: measured_at)
    }

    func isStale(now: Date = Date()) -> Bool {
        guard let measured = measuredDate else { return true }
        return now.timeIntervalSince(measured) > Self.staleAfterSeconds
    }

    /// "Down 42.1 Mbps · Up 18.3 Mbps · RTT 48 ms"
    var valuesText: String {
        "Down \(Self.mbps(down_mbps)) · Up \(Self.mbps(up_mbps)) · RTT \(Self.milliseconds(rtt_ms))"
    }

    var methodText: String {
        switch method {
        case "iperf3": return "iperf3, router to router"
        case "ssh":    return "SSH copy (lower bound)"
        default:       return method
        }
    }

    var measuredText: String {
        guard let measured = measuredDate else { return measured_at }
        return measured.formatted(date: .abbreviated, time: .shortened)
    }

    /// Missing, unreadable or malformed files yield nil; the caller shows nothing.
    static func load(from path: String) -> SpeedSnapshot? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.uncached]) else { return nil }
        return try? JSONDecoder().decode(SpeedSnapshot.self, from: data)
    }

    private static func mbps(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f Mbps", value)
    }

    private static func milliseconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f ms", value)
    }
}

enum SpeedRequest {
    /// Updates the trigger file the speed check's LaunchDaemon watches. The installer creates it
    /// world-writable, so no admin rights are needed. Returns false if the file does not exist
    /// (speed check not installed) or cannot be written; never creates the file.
    static func write(to path: String, now: Date = Date()) -> Bool {
        guard let handle = FileHandle(forWritingAtPath: path) else { return false }
        defer { try? handle.close() }
        let stamp = ISO8601DateFormatter().string(from: now) + "\n"
        do {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(stamp.utf8))
            return true
        } catch {
            return false
        }
    }
}
