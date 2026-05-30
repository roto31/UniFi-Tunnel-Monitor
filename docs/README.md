# Public documentation index

Guides for UniFi users replicating **two-sided VPN health monitoring**, **OpenVPN site-to-site** (when IPsec is blocked), and **WAN Guard** (dual-WAN DDNS protection).

All examples use **placeholders**. Configure real values via [`PLACEHOLDERS.md`](../PLACEHOLDERS.md).

---

## Start here

| Audience | Read first |
|----------|------------|
| New to the project | [getting-started.md](getting-started.md) |
| Ready to deploy | [implementation-guide.md](implementation-guide.md) |
| Tunnel already up, need monitors | [architecture.md](architecture.md) |
| Something broke | [troubleshooting.md](troubleshooting.md) |

---

## Guides by topic

### Core monitoring

| Document | Description |
|----------|-------------|
| **[tunnel-monitor/](tunnel-monitor/README.md)** | **Tunnel Monitor.app** — overview, architecture, setup (screenshots), usage, troubleshooting |
| [architecture.md](architecture.md) | Components, dedup, state machine, diagrams |
| [spoke-monitoring.md](spoke-monitoring.md) | Optional remote gateway + LAN monitors |
| [../spoke/README.md](../spoke/README.md) | Spoke config templates + deploy scripts |
| [../mac/README.md](../mac/README.md) | Mac / LAN-client install + CLI |
| [../unifi/README.md](../unifi/README.md) | UniFi gateway install + CLI |

### VPN transport

| Document | Description |
|----------|-------------|
| [openvpn-site-to-site-migration.md](openvpn-site-to-site-migration.md) | OpenVPN when upstream modem blocks IPsec |
| [wan-guard-openvpn-failover.md](wan-guard-openvpn-failover.md) | Dual-WAN + DDNS + OpenVPN stability |
| [../unifi/wan-guard/README.md](../unifi/wan-guard/README.md) | WAN Guard quick install |

### Reference

| Document | Description |
|----------|-------------|
| [network-overview.md](network-overview.md) | Generic topology (placeholder IPs) |
| [implementation-guide.md](implementation-guide.md) | End-to-end replication checklist |
| [troubleshooting.md](troubleshooting.md) | Beginner steps + advanced diagnosis |
| [../PLACEHOLDERS.md](../PLACEHOLDERS.md) | Every config placeholder |

---

## Terminology (public)

| Term | Meaning |
|------|---------|
| **Local hub** | Your home/office UniFi gateway (runs optional WAN Guard) |
| **Remote spoke** | The other site's UniFi gateway |
| **LAN client monitor** | Mac (or Linux/Windows port) on the local LAN |
| **Gateway monitor** | Bash + systemd on the UniFi gateway |
| **Dedup** | Mac suppresses email when gateway already alerted |

---

## External references

- [Ubiquiti — OpenVPN Site-to-Site](https://help.ui.com/hc/en-us/articles/12646699585047-UniFi-Gateway-OpenVPN-Site-to-Site)
- [Ubiquiti — Site-to-Site VPN overview](https://help.ui.com/hc/en-us/articles/115001218267-UniFi-Gateway-Route-Based-VPN-IPsec)
- [No-IP update API](https://www.noip.com/integrate/response)
- [RFC 5737 — documentation IPv4 blocks](https://www.rfc-editor.org/rfc/rfc5737)

---

## License

MIT — see [../LICENSE](../LICENSE). No warranty; read scripts before production use.
