import Foundation

struct WizardFieldSpec: Codable, Identifiable, Hashable {
    var id: String { key }
    let key: String
    let label: String
    let secure: Bool
    let defaultValue: String?
    let help: String?

    enum CodingKeys: String, CodingKey {
        case key, label, secure, help
        case defaultValue = "default"
    }
}

struct WizardSectionSpec: Codable, Identifiable {
    var id: String { title }
    let title: String
    let fields: [WizardFieldSpec]
}

struct WizardCatalog: Codable {
    let sections: [WizardSectionSpec]
}

enum WizardFieldLoader {
    static func load() -> WizardCatalog {
        if let url = Bundle.main.url(forResource: "wizard-fields", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let cat = try? JSONDecoder().decode(WizardCatalog.self, from: data) {
            return cat
        }
        // Fallback if Resources/wizard-fields.json was not copied into the .app bundle.
        return fallbackCatalog()
    }

    private static func fallbackCatalog() -> WizardCatalog {
        let data = Data(fallbackJSON.utf8)
        if let cat = try? JSONDecoder().decode(WizardCatalog.self, from: data) {
            return cat
        }
        return WizardCatalog(sections: [])
    }

    private static let fallbackJSON = """
    {
      "sections": [
        {
          "title": "SMTP",
          "fields": [
            {"key": "SMTP_SERVER", "label": "SMTP server", "secure": false, "default": "smtp.mail.me.com", "help": "e.g. smtp.mail.me.com or smtp.gmail.com"},
            {"key": "SMTP_PORT", "label": "SMTP port", "secure": false, "default": "587", "help": null},
            {"key": "SMTP_USER", "label": "SMTP username (email)", "secure": false, "default": "", "help": null},
            {"key": "SMTP_PASSWORD", "label": "App-specific password", "secure": true, "default": "", "help": "Not your account password."},
            {"key": "ALERT_FROM", "label": "From address", "secure": false, "default": "", "help": "Often must match SMTP_USER."},
            {"key": "ALERT_TO", "label": "Alert recipient", "secure": false, "default": "", "help": null}
          ]
        },
        {
          "title": "Topology",
          "fields": [
            {"key": "REMOTE_LAN_IP", "label": "Remote LAN gateway (over tunnel)", "secure": false, "default": "", "help": null},
            {"key": "REMOTE_WAN_IP", "label": "Remote public IP (expected)", "secure": false, "default": "", "help": null},
            {"key": "REMOTE_DDNS", "label": "DDNS hostname", "secure": false, "default": "", "help": null}
          ]
        },
        {
          "title": "Router dedup (SSH)",
          "fields": [
            {"key": "UDR7_HOST", "label": "Router LAN IP (SSH target)", "secure": false, "default": "192.168.1.1", "help": null},
            {"key": "UDR7_USER", "label": "SSH user", "secure": false, "default": "root", "help": null},
            {"key": "UDR7_KEY", "label": "SSH private key path", "secure": false, "default": "/opt/tunnel-monitor/.ssh/id_ed25519", "help": null},
            {"key": "UDR7_STATE_PATH", "label": "Remote state file path", "secure": false, "default": "/data/tunnel-monitor/state", "help": null}
          ]
        },
        {
          "title": "Tuning & subjects",
          "fields": [
            {"key": "SUBJECT_PREFIX", "label": "Email subject prefix", "secure": false, "default": "[MAC]", "help": null},
            {"key": "FAILURE_THRESHOLD", "label": "Failures before alert", "secure": false, "default": "3", "help": null},
            {"key": "PING_COUNT", "label": "Pings per check", "secure": false, "default": "3", "help": null},
            {"key": "PING_TIMEOUT", "label": "Ping timeout (seconds)", "secure": false, "default": "2", "help": null},
            {"key": "NOTIFY_SOUND_DOWN", "label": "Banner sound (down)", "secure": false, "default": "Glass", "help": null},
            {"key": "NOTIFY_SOUND_RECOVERY", "label": "Banner sound (recovery)", "secure": false, "default": "Hero", "help": null}
          ]
        }
      ]
    }
    """
}
