import Foundation

/// Builds `/opt/tunnel-monitor/config.env` contents from wizard field values.
enum ConfigEnvWriter {
    static func renderLines(_ pairs: [(key: String, value: String)]) -> String {
        var lines: [String] = []
        lines.append("# =============================================================================")
        lines.append("# Tunnel Monitor — configuration (written by setup wizard)")
        lines.append("# =============================================================================")
        lines.append("")
        for p in pairs {
            lines.append("\(p.key)=\"\(escapeValue(p.value))\"")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func escapeValue(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
