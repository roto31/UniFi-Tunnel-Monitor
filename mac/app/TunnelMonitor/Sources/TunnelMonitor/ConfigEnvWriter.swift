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

    /// Replace wizard keys in an existing config.env and append any that are new.
    /// Comments and unknown keys are kept. ROUTER_*/UDR7_* aliases are filled in.
    static func merge(existing: String, pairs: [(key: String, value: String)]) -> String {
        let expanded = withDedupAliases(pairs)
        var updates: [String: String] = [:]
        for pair in expanded {
            updates[pair.key] = pair.value
        }
        var seen = Set<String>()
        var lines = existing.components(separatedBy: "\n")
        for index in lines.indices {
            let line = lines[index]
            guard let key = configKey(in: line), let value = updates[key] else { continue }
            lines[index] = "\(key)=\"\(escapeValue(value))\""
            seen.insert(key)
        }
        var extras: [String] = []
        for pair in expanded where !seen.contains(pair.key) {
            extras.append("\(pair.key)=\"\(escapeValue(pair.value))\"")
            seen.insert(pair.key)
        }
        if !extras.isEmpty {
            if lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append(contentsOf: extras)
        }
        return lines.joined(separator: "\n")
    }

    private static func configKey(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.allSatisfy({ $0 == "_" || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") }) else {
            return nil
        }
        return key
    }

    private static func escapeValue(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
