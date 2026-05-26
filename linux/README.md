# Linux side — Tunnel Monitor (systemd LAN client)

A generic Linux LAN-client port of the Mac edition. A systemd timer pings a
site-to-site IPsec VPN from a **LAN client perspective**, deduplicates
against a sibling monitor on the gateway, and exposes status to a
`tunnel-check` CLI and (optionally) the cross-platform tray app in
[`../tray-app/`](../tray-app/).

This is the **Linux LAN-client side**. The matching gateway side lives in
[`../unifi/`](../unifi/) (UniFi-specific), and the macOS LAN client lives in
[`../mac/`](../mac/).

---

## What it does

Every 5 minutes the systemd unit runs `monitor.sh`, which:

1. Pings `REMOTE_LAN_IP` over the tunnel (the remote site's LAN gateway).
2. Pings `REMOTE_WAN_IP` directly over the internet (the remote site's
   public IP). Distinguishes "tunnel down" from "remote site offline".
3. Pings `1.1.1.1` as a sanity check on the local internet.
4. Resolves `REMOTE_DDNS` via `dig` and compares against `REMOTE_WAN_IP` to
   detect DDNS drift.
5. SSHes to the gateway and reads `/data/tunnel-monitor/state` to see what
   the router-side monitor thinks (dedup signal).
6. Updates `/opt/tunnel-monitor/state.json` atomically with all of the above.
7. If failures cross `FAILURE_THRESHOLD` (default 3 -> ~15 min outage),
   sends an email. If the router-side monitor already alerted, the email
   is suppressed.
8. When the tunnel recovers after being marked DOWN, sends a recovery email.

The optional tray app reads `state.json` and never runs its own checks.

> **No desktop banners from the timer.** The macOS edition fires a
> Notification Center banner via `osascript`. There is no clean Linux
> equivalent that works reliably across Wayland, X11, and headless installs
> from a root-owned systemd unit, so `notify.sh` is intentionally a no-op
> stub that logs `NOTIFY_SKIPPED`. Use email + the tray app for desktop
> awareness.

---

## Prerequisites

- Any modern Linux distribution with **systemd** (Debian/Ubuntu, Fedora/RHEL,
  Arch, openSUSE, etc.).
- `bash`, `jq`, `curl`, `dig` (`dnsutils` / `bind-utils`), `ssh`, `ssh-keygen`,
  `ping` (`iputils-ping`).
- Root access (`sudo`).
- A gateway running the sibling monitor from [`../unifi/`](../unifi/)
  (optional but recommended — without it, dedup collapses and the Linux
  client alerts on its own).
- An SMTP account capable of authenticated submission on port 587.

### Distro install hints

```bash
# Debian / Ubuntu
sudo apt update && sudo apt install -y jq curl dnsutils openssh-client iputils-ping

# Fedora / RHEL / CentOS Stream
sudo dnf install -y jq curl bind-utils openssh-clients iputils

# Arch
sudo pacman -S --needed jq curl bind openssh iputils
```

---

## File layout (after install)

```
/opt/tunnel-monitor/
+-- monitor.sh                  # health check + state machine + alert dispatch
+-- send-email.sh               # authenticated SMTP submission via curl
+-- notify.sh                   # no-op desktop notification stub
+-- tunnel-check                # operator CLI (symlinked to /usr/local/bin/)
+-- ssh-router-state.sh         # reads router state file via SSH for dedup
+-- config.env                  # SMTP creds + topology + tuning (chmod 0600)
+-- config.env.template         # safe-to-share template
+-- state.json                  # current health state (atomic writes)
+-- monitor.log                 # rolling log (rotates at 1 MB)
+-- .ssh/
    +-- id_ed25519              # private SSH key for router dedup (chmod 0600)
    +-- id_ed25519.pub
    +-- known_hosts

/etc/systemd/system/
+-- tunnel-monitor.service      # oneshot health check
+-- tunnel-monitor.timer        # 5-minute interval (OnUnitActiveSec=5min)

/usr/local/bin/
+-- tunnel-check -> /opt/tunnel-monitor/tunnel-check
```

---

## Install

```bash
# 1. Run the installer (it re-execs under sudo if needed)
sudo bash install.sh

# 2. Edit the config to set SMTP creds and remote topology
sudo vi /opt/tunnel-monitor/config.env
#   Replace every REPLACE_WITH_* value.

# 3. Re-run the installer to push the SSH key to your router now that
#    ROUTER_HOST is set. (The installer detects the placeholder and skips
#    SSH auth on the first run.)
sudo bash install.sh

# 4. Smoke test
tunnel-check --test-email      # email plumbing
sudo tunnel-check --check-now  # force a real health check

# 5. Verify
sudo bash verify.sh
```

The installer is idempotent: re-running never destroys `config.env` or
`state.json`. The SSH key is generated only when missing.

---

## Configuration

All knobs live in `/opt/tunnel-monitor/config.env`. See
[`../PLACEHOLDERS.md`](../PLACEHOLDERS.md) for what each `REPLACE_WITH_*`
value means.

**The minimum you must set:**

- `SMTP_SERVER`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`
- `ALERT_FROM`, `ALERT_TO`
- `REMOTE_LAN_IP`, `REMOTE_WAN_IP`, `REMOTE_DDNS`
- `ROUTER_HOST`, `ROUTER_USER` (if you want dedup with the router side)

**Useful tuning:**

| Var                 | Default   | Notes                                              |
|---------------------|-----------|----------------------------------------------------|
| `FAILURE_THRESHOLD` | `3`       | Consecutive failures before alerting (x 5 min = ~15 min) |
| `PING_COUNT`        | `3`       | Pings per check                                    |
| `PING_TIMEOUT`      | `2`       | Seconds (GNU `ping -W`)                            |
| `SUBJECT_PREFIX`    | `[LINUX]` | Prepended to every email subject                   |

---

## CLI cheat sheet

| Command                              | What it does                                  |
|--------------------------------------|-----------------------------------------------|
| `tunnel-check`                       | Pretty-print current status from `state.json` |
| `sudo tunnel-check --check-now`      | Force a systemd-triggered run right now       |
| `tunnel-check --test-email`          | Synthetic email through `send-email.sh`       |
| `tunnel-check --test-notify`         | Exercise `notify.sh` stub (logs only)         |
| `sudo tunnel-check --reset`          | Reset `state.json` to a fresh `UP/0`          |
| `tunnel-check --tail`                | `tail -f /opt/tunnel-monitor/monitor.log`     |
| `tunnel-check --history`             | Last 50 log lines                             |
| `tunnel-check --ssh-test`            | Verify SSH-based router dedup works           |
| `tunnel-check --status`              | `systemctl status` of the timer + service     |

---

## Diagnoses (same contract as Mac edition)

| Diagnosis              | What it means                                            | What to do                                            |
|------------------------|----------------------------------------------------------|-------------------------------------------------------|
| `TUNNEL_DOWN`          | Pings fail; DNS / internet look fine                     | SSH the router: `journalctl -fu strongswan -n 100`    |
| `DDNS_DRIFT`           | `REMOTE_DDNS` no longer resolves to `REMOTE_WAN_IP`      | Log into your DDNS provider; update the A record      |
| `REMOTE_INTERNET_DOWN` | Remote site's public IP unreachable                      | Nothing to do - wait or call the remote site          |
| `ROUTER_UNREACHABLE`   | Tunnel down AND Linux client can't SSH the router        | Verify router is up; reboot if frozen                 |
| `DISAGREEMENT`         | Router says UP but Linux client sees DOWN                | `ping ROUTER_HOST`; restart networking; check VLAN    |
| `OUR_INTERNET_DOWN`    | Local internet is down                                   | No alert sent. Wait for our internet to recover       |

---

## Recovery from kernel / distro updates

The unit files at `/etc/systemd/system/tunnel-monitor.*` survive package
upgrades. If a major update somehow disables the timer:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now tunnel-monitor.timer
sudo bash verify.sh
```

Just re-run `install.sh` if anything else looks off - it's idempotent.

---

## Uninstall

```bash
sudo bash uninstall.sh           # interactive - asks before destroying config + state
sudo bash uninstall.sh --keep    # keep config.env + state.json
sudo bash uninstall.sh --yes     # remove everything, no prompts
```
