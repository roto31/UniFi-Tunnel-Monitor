import Foundation

/// Values from `Info.plist` so the same binary layout supports private vs Public/sanitized builds.
enum AppBranding {
    private static func string(for key: String, default def: String) -> String {
        guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return def
        }
        return v
    }

    static var launchDaemonLabel: String {
        string(for: "TMLaunchDaemonLabel", default: "com.ruter.tunnel-monitor")
    }

    /// Menu / status section title for the SSH dedup row block.
    static var dedupSectionTitle: String {
        string(for: "TMDedupSectionTitle", default: "UDR7 dedup")
    }

    static var statusBannerTitle: String {
        string(for: "TMStatusBannerTitle", default: "Tunnel Monitor")
    }
}
