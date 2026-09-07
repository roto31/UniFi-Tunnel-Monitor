import Foundation

/// Builds `/opt/tunnel-monitor/config.env` contents from wizard field values.
enum ConfigEnvWriter {
    static func renderLines(_ pairs: [(key: String, value: String)]) -> String {
        var lines: [String] = []
        lines.append("# =============================================================================")
        lines.append("# Tunnel Monitor — configuration (written by setup wizard)")
        lines.append("# =============================================================================")
        lines.append("")
        for p in withDedupAliases(pairs) {
            lines.append("\(p.key)=\"\(escapeValue(p.value))\"")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Payload scripts read ROUTER_*; some app builds wrote UDR7_*. Persist both.
    static func withDedupAliases(_ pairs: [(key: String, value: String)]) -> [(key: String, value: String)] {
        var map: [String: String] = [:]
        for p in pairs {
            map[p.key] = p.value
        }
        let aliases = [
            ("ROUTER_HOST", "UDR7_HOST"),
            ("ROUTER_USER", "UDR7_USER"),
            ("ROUTER_KEY", "UDR7_KEY"),
            ("ROUTER_STATE_PATH", "UDR7_STATE_PATH"),
        ]
        for (routerKey, udrKey) in aliases {
            let routerVal = map[routerKey] ?? ""
            let udrVal = map[udrKey] ?? ""
            if routerVal.isEmpty && !udrVal.isEmpty {
                map[routerKey] = udrVal
            }
            if udrVal.isEmpty && !routerVal.isEmpty {
                map[udrKey] = routerVal
            }
        }
        var seen = Set<String>()
        var out: [(key: String, value: String)] = []
        for p in pairs {
            out.append((key: p.key, value: map[p.key] ?? p.value))
            seen.insert(p.key)
        }
        for (routerKey, udrKey) in aliases {
            if !seen.contains(routerKey), let value = map[routerKey], !value.isEmpty {
                out.append((key: routerKey, value: value))
                seen.insert(routerKey)
            }
            if !seen.contains(udrKey), let value = map[udrKey], !value.isEmpty {
                out.append((key: udrKey, value: value))
                seen.insert(udrKey)
            }
        }
        return out
    }

    private static func escapeValue(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
