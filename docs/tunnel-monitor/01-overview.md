# Application overview

[← Hub](README.md)

## Why Tunnel Monitor exists

Site-to-site VPNs (OpenVPN or IPsec on UniFi gateways) can fail silently from the perspective of users on the LAN: the router may still show “connected” while traffic to the remote site does not flow. Operators historically relied on **command-line checks**, a **bash daemon** on the Mac, and optionally **SwiftBar** to read health state.

**Tunnel Monitor** adds a native **macOS menu bar application** that:

- Shows tunnel health at a glance (green / yellow / red).
- Opens a **Configuration** window to write `/opt/tunnel-monitor/config.env` without manual `sudo vi` (for users who prefer a GUI).
- Exposes one-click actions (force check, test email, test notification, SSH test, and more).

The app **does not replace** the LaunchDaemon. All pings, DNS checks, SSH dedup, email, and banners still run in `monitor.sh` every five minutes.

---

## What it does

| Capability | Who performs it |
|------------|-----------------|
| Ping remote LAN gateway over the tunnel | `monitor.sh` (LaunchDaemon) |
| Ping remote public IP and local internet (1.1.1.1) | `monitor.sh` |
| Compare DDNS resolution to expected WAN IP | `monitor.sh` |
| Read gateway sibling monitor state over SSH (dedup) | `monitor.sh` |
| Write `/opt/tunnel-monitor/state.json` | `monitor.sh` |
| Email alert after consecutive failures (default 3 ≈ 15 min) | `send-email.sh` via `monitor.sh` |
| macOS banner on down / recovery | `notify.sh` via `monitor.sh` |
| Display status, issues, downtime | Tunnel Monitor.app (reads `state.json`) |
| Edit SMTP / topology / tuning via GUI | Configuration window → `config.env` |
| Force immediate daemon run | App → `launchctl kickstart` |

Monitoring is **transport-agnostic**: it does not inspect the OpenVPN or IPsec process. It infers health from reachability and DNS, which matches how the bash monitor was designed. If you migrated from IPsec to OpenVPN, see [openvpn-site-to-site-migration.md](../openvpn-site-to-site-migration.md).

---

## What it does not do

- Monitor arbitrary VPNs or cloud tunnels (built for one site-to-site pair per `config.env`).
- Run health checks inside the GUI process (no in-app ping).
- Store SMTP passwords outside `config.env` (never log passwords).
- Replace the UniFi gateway-side monitor (dedup assumes a sibling monitor on the hub gateway).

---

## Key features (GUI)

- **Traffic-light menu bar dot** — green (healthy), yellow (issues before alert threshold), red (`alert_state` DOWN).
- **Menu bar popover** — checks, dedup line, failure count, action buttons.
- **Configuration window** — four sections: SMTP, tunnel topology, gateway SSH, tuning (see [03-setup-installation.md](03-setup-installation.md)).
- **Optional dashboard window** — same status content with a window title bar.
- **Settings** — menu bar / Dock visibility, poll interval (5 / 15 / 30 s), optional widget sync (Xcode build with widget extension).
- **Launch at login** — `SMAppService` toggle in the popover footer.

---

## Skill-level quick paths

### Beginner

1. Install the `.pkg` from [GitHub Releases](https://github.com/roto31/UniFi-Tunnel-Monitor/releases).
2. Open **Tunnel Monitor** from Applications; complete **Configuration** (admin password to save).
3. Use **Copy SSH Auth Cmd** and **SSH Test** in the menu bar popover.
4. Run **Test Email** and **Test Notify**.

### Operator

- Use the menu bar popover daily; open **Setup…** to change `config.env`.
- Use **Force Check** after topology or No-IP changes.
- Read [05-troubleshooting.md](05-troubleshooting.md) when the dot turns yellow or red.

### Advanced

- `sudo bash install.sh` from a clone; edit `config.env` by hand.
- `tunnel-check`, `tail -f /opt/tunnel-monitor/monitor.log`, launchd / plist inspection.
- Read [02-architecture.md](02-architecture.md) and [../../mac/README.md](../../mac/README.md).
