# Tunnel Monitor — documentation hub

End-to-end guide for the **Tunnel Monitor** macOS stack: a LaunchDaemon that watches your site-to-site VPN (OpenVPN or IPsec) from a Mac on the LAN, plus a menu bar app that displays status and runs operator actions.

**Audience routing**

| You are… | Start here |
|----------|------------|
| New user (install + first config) | [03-setup-installation.md](03-setup-installation.md) → [04-usage-guide.md](04-usage-guide.md) |
| Operator (daily use, alerts) | [04-usage-guide.md](04-usage-guide.md) → [05-troubleshooting.md](05-troubleshooting.md) |
| Integrator / developer | [02-architecture.md](02-architecture.md) → [../architecture.md](../architecture.md) → [../../mac/README.md](../../mac/README.md) |

---

## Table of contents

1. [Application overview](01-overview.md) — why it exists, what it does, what it does not do  
2. [Architecture & diagrams](02-architecture.md) — components, data flow, alerts, GUI layer  
3. [Setup & installation](03-setup-installation.md) — pkg, Configuration window, `config.env` fields  
4. [How-to & usage guide](04-usage-guide.md) — every screen, actions, screenshots  
5. [Troubleshooting](05-troubleshooting.md) — common issues, diagnosis codes, GUI notes  

---

## Related docs (not duplicated here)

| Topic | Document |
|-------|----------|
| Full monitoring stack (gateway + Mac + WAN Guard) | [../architecture.md](../architecture.md) |
| Mac install paths, CLI | [../../mac/README.md](../../mac/README.md) |
| OpenVPN when IPsec is blocked | [../openvpn-site-to-site-migration.md](../openvpn-site-to-site-migration.md) |
| Config placeholders | [../../PLACEHOLDERS.md](../../PLACEHOLDERS.md) |
| General VPN troubleshooting | [../troubleshooting.md](../troubleshooting.md) |
| Release build / signing | [Build and Release](https://github.com/roto31/UniFi-Tunnel-Monitor/wiki/Build-and-Release) (wiki) |

---

## Out of scope for this hub

- Full rewrite of all legacy architecture/troubleshooting pages (this hub links to them).  
- Automatic wiki publishing (sync [`.wiki-uni-tunnel-monitor/`](https://github.com/roto31/UniFi-Tunnel-Monitor/wiki) manually if needed).  
- Notarization and codesigning detail (see wiki **Build and Release** only).
