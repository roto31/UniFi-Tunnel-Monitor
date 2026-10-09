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

    /// Menu title for the optional spoke policy-route card.
    static var spokePolicySectionTitle: String {
        string(for: "TMSpokePolicySectionTitle", default: "Spoke policy route")
    }

    /// Short gateway name taken from the dedup section title ("UDR7 dedup" → "UDR7").
    static var routerShortName: String {
        let title = dedupSectionTitle
        let suffix = " dedup"
        if title.lowercased().hasSuffix(suffix) {
            return String(title.dropLast(suffix.count))
        }
        return title
    }
}
