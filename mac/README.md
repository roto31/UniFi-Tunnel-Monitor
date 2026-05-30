# Mac side — Tunnel Monitor (launchd + SwiftBar)

A macOS LaunchDaemon that pings a site-to-site IPsec VPN from a **LAN client
perspective**, deduplicates against a sibling monitor on the UniFi gateway,
and exposes status to a SwiftBar menu-bar plugin and a `tunnel-check` CLI.

This is the **Mac side**. The matching UniFi-gateway side lives in
[`../unifi/`](../unifi/).

**Tunnel Monitor.app (GUI):** full guide with screenshots —
[`../docs/tunnel-monitor/`](../docs/tunnel-monitor/README.md).

---

## What it does

Every 5 minutes the LaunchDaemon runs `monitor.sh`, which:

1. Pings `REMOTE_LAN_IP` over the tunnel (the remote site's LAN gateway).
2. Pings `REMOTE_WAN_IP` directly over the internet (the remote site's
   public IP). Distinguishes "tunnel down" from "remote site offline".
3. Pings `1.1.1.1` as a sanity check on the Mac's own internet.
4. Resolves `REMOTE_DDNS` via `dig` and compares against `REMOTE_WAN_IP` to
   detect DDNS drift.
5. SSHes to the UniFi gateway and reads `/data/tunnel-monitor/state` to see
   what the router-side monitor thinks (dedup signal).
6. Updates `/opt/tunnel-monitor/state.json` atomically with all of the above.
7. If failures cross `FAILURE_THRESHOLD` (default 3 → ~15 min outage),
   sends an email **and** posts a macOS banner. If the router-side monitor
   already alerted, the email is suppressed but the banner still fires.
8. When the tunnel recovers after being marked DOWN, sends a recovery email
   + banner.

The SwiftBar plugin reads `state.json` once every 30 seconds and never runs
its own checks — single source of truth.

---

## Prerequisites

- macOS 12 (Monterey) or later.
- [Homebrew](https://brew.sh).
- `jq` — `brew install jq` (the installer will do this for you).
- [SwiftBar](https://github.com/swiftbar/SwiftBar) (optional; install with
  `brew install --cask swiftbar`).
- A UniFi gateway on the same LAN running the sibling monitor from
  [`../unifi/`](../unifi/) (optional but the whole dedup story collapses
  without it — the Mac will alert on its own with no de-duplication).
- An SMTP account capable of authenticated submission on port 587.
  Tested with iCloud (`smtp.mail.me.com`), generic for any provider.

---

## File layout (after install)

```
/opt/tunnel-monitor/
├── monitor.sh                  # health check + state machine + alert dispatch
├── send-email.sh               # authenticated SMTP submission via curl
├── notify.sh                   # banner via launchctl asuser + osascript
├── tunnel-check                # operator CLI (symlinked to /usr/local/bin/)
├── ssh-router-state.sh         # reads router state file via SSH for dedup
├── config.env                  # SMTP creds + topology + tuning (chmod 0600)
├── config.env.template         # safe-to-share template
├── state.json                  # current health state (atomic writes)
├── monitor.log                 # rolling log (rotates at 1 MB)
├── launchd.stdout.log          # launchd-captured stdout
├── launchd.stderr.log          # launchd-captured stderr
└── .ssh/
    ├── id_ed25519              # private SSH key for router dedup (chmod 0600)
    ├── id_ed25519.pub
    └── known_hosts

/Library/LaunchDaemons/
└── com.example.tunnel-monitor.plist   # 5-min interval, RunAtLoad

/usr/local/bin/
└── tunnel-check -> /opt/tunnel-monitor/tunnel-check

~/Library/Application Support/SwiftBar/Plugins/
└── tunnel-monitor.30s.sh
```

### Menu bar app (`app/`)

The sanitized SwiftUI app lives in [`app/TunnelMonitor/`](app/TunnelMonitor/). It
matches the private repo layout but uses `com.example.tunnel.monitor`,
`com.example.tunnel-monitor` for LaunchDaemon kicks, `ROUTER_*` keys in the
setup wizard, and reads `router_dedup` from `state.json`.

- **Sync Swift from the private tree** (after you edit the main app under
  `../../app/TunnelMonitor/`): from `Public/mac/`, run `bash sync-app-from-root.sh`
- **Build** `.app` into the repo’s `build/dist/`: from `Public/mac/app/`, run
  `bash build-app.sh`

On first launch the app opens a **configuration sheet** for
`/opt/tunnel-monitor/config.env` (admin password required to save). Use
**Configure later** if you prefer `sudo vi`. To show the sheet again, use
**Setup…** in the menu.

---

## Install

> ⚠️ Before you start, review and rename `com.example.tunnel-monitor` to
> something under your own reverse-DNS namespace (e.g.
> `com.yourusername.tunnel-monitor`). See [`../PLACEHOLDERS.md`](../PLACEHOLDERS.md)
> for the one-liner search-and-replace.

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
tunnel-check --test-notify     # banner plumbing
sudo tunnel-check --check-now  # force a real health check

# 5. Verify
sudo bash verify.sh
```

The installer is idempotent — re-running never destroys `config.env` or
`state.json`. The SSH key is generated only when missing.

### First-time notification permission

macOS will silently drop the first banner because Notification Center has
not yet authorized `osascript`. After running `tunnel-check --test-notify`:

1. Open **System Settings → Notifications**.
2. Find "Script Editor" or `osascript` and toggle **Allow Notifications** on.
3. Re-run `tunnel-check --test-notify`. The banner should now appear.

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

| Var                 | Default  | Notes                                              |
|---------------------|----------|----------------------------------------------------|
| `FAILURE_THRESHOLD` | `3`      | Consecutive failures before alerting (× 5 min = ~15 min) |
| `PING_COUNT`        | `3`      | Pings per check                                    |
| `PING_TIMEOUT`      | `2`      | Seconds — converted to ms for BSD `ping -W`        |
| `SUBJECT_PREFIX`    | `[MAC]`  | Prepended to every email subject                   |

---

## CLI cheat sheet

| Command                              | What it does                                  |
|--------------------------------------|-----------------------------------------------|
| `tunnel-check`                       | Pretty-print current status from `state.json` |
| `sudo tunnel-check --check-now`      | Force a launchd-triggered run right now       |
| `tunnel-check --test-email`          | Synthetic email through `send-email.sh`       |
| `tunnel-check --test-notify`         | Synthetic banner through `notify.sh`          |
| `sudo tunnel-check --reset`          | Reset `state.json` to a fresh `UP/0`          |
| `tunnel-check --tail`                | `tail -f /opt/tunnel-monitor/monitor.log`     |
| `tunnel-check --history`             | Last 50 log lines                             |
| `tunnel-check --ssh-test`            | Verify SSH-based router dedup works           |
| `tunnel-check --status`              | `launchctl print` of the daemon               |

---

## Script reference

### `monitor.sh` — health check + state machine + alert dispatch

Sourced behaviour (cite by line; see the file for full code):

- `set -uo pipefail` then an `EXIT` trap that forces `exit 0`, so launchd
  never throttles the job even when a sub-command unexpectedly fails.
- Reads `/opt/tunnel-monitor/config.env`; aborts cleanly with a log entry if
  missing.
- Runs all four health checks (`tunnel`, `remote_wan`, `our_internet`, `dns`)
  in `run_health_checks()`.
- Queries the router-side state file via `ssh-router-state.sh` on every run
  (not just on failure) so SwiftBar always has fresh dedup data.
- Applies the diagnosis decision tree (`diagnose()`) in this order, first
  match wins:
  1. `OUR_INTERNET_DOWN` — our internet is unreachable; hold state, don't alert.
  2. `HEALTHY` — tunnel ping succeeded; reset counter, possibly send recovery.
  3. `ROUTER_UNREACHABLE` — tunnel down AND SSH to router failed.
  4. `DISAGREEMENT` — router says `0:UP` but Mac sees the tunnel down.
  5. `DDNS_DRIFT` — DNS resolution doesn't match `REMOTE_WAN_IP`.
  6. `REMOTE_INTERNET_DOWN` — remote public IP also unreachable.
  7. `TUNNEL_DOWN` — fallback: pings fail but everything else looks fine.
- State machine: increments `failure_count` on any non-HEALTHY/non-OUR_INTERNET
  diagnosis. Transitions to `DOWN` when `failure_count >= FAILURE_THRESHOLD`.
  Sends recovery email + banner on `DOWN → UP` transition.
- Dedup: when transitioning to DOWN, suppress email if the router's state
  file reports `*:DOWN`. Banner always fires.
- Atomic writes: `jq -n` to a `.tmp` file, then `mv`.
- Sub-commands: `check` (default), `diagnose`, `notify-test`, `email-test`,
  `ssh-test`, `--help`.

### `send-email.sh` — authenticated SMTP submission

- Usage: `send-email.sh <subject> <body-file>`.
- Reads `SMTP_SERVER`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `ALERT_FROM`,
  `ALERT_TO`, `SUBJECT_PREFIX` from `config.env`.
- Validates that every required variable is set and that `SMTP_PASSWORD`
  isn't still the template placeholder.
- Builds an RFC822 message in a temp file (CRLF line endings; explicit
  `Message-ID` header).
- Submits via `curl --ssl-reqd --url smtp://...` with `--mail-from`,
  `--mail-rcpt`, `--upload-file`. Connect timeout 10 s, total timeout 30 s.
- Exit codes: `0` success, `1` runtime failure (curl error), `2` config
  error (missing var, placeholder password, body file missing), `3` bad
  invocation (wrong arg count).

### `ssh-router-state.sh` — router-side dedup query

- Reads `ROUTER_HOST`, `ROUTER_USER`, `ROUTER_KEY`, `ROUTER_STATE_PATH` from
  `config.env`.
- Runs `ssh -i KEY USER@HOST 'cat ROUTER_STATE_PATH'` with these options:
  `BatchMode=yes` (never prompt), `ConnectTimeout=5`, `ServerAliveInterval=3`,
  `ServerAliveCountMax=2`, `StrictHostKeyChecking=accept-new`,
  `UserKnownHostsFile=/opt/tunnel-monitor/.ssh/known_hosts`.
- Validates the remote state line matches `^[0-9]+:(UP|DOWN)$` before
  printing it. Malformed → exit non-zero so the caller treats it as
  "router unreachable" rather than feeding garbage into the diagnosis tree.
- Exit codes: `0` success, `1` SSH failure or unparseable state, `2`
  config error (missing config.env or SSH key file).

### `notify.sh` — native macOS banner from a root daemon

- Usage: `notify.sh <title> <message> [sound]` (default sound: `Glass`).
- Resolves the console user via `stat -f "%Su" /dev/console` and the UID via
  `stat -f "%u" /dev/console`. Falls back to a silent no-op when no GUI user
  is logged in.
- When invoked by the console user directly (`tunnel-check --test-notify`),
  calls `osascript` directly.
- When invoked by the root daemon, injects the call into the user session
  via `launchctl asuser <uid> sudo -u <user> osascript -e 'display
  notification ...'`. The entire call is wrapped in `timeout 5` so a hung
  Notification Center never blocks the daemon.
- Properly escapes double-quotes and backslashes in `title` and `message`
  before injecting them into the AppleScript literal.

### `tunnel-check` — operator CLI

- Reads `/opt/tunnel-monitor/state.json` via `jq` and prints a colourized
  status table.
- Dispatches sub-commands per the table above. `--check-now`, `--reset`,
  and `--status` require root.

---

## Alert response runbook

Each diagnosis ships with an actionable hint in the email subject AND in
the SwiftBar dropdown.

| Diagnosis              | What it means                                            | What to do                                            |
|------------------------|----------------------------------------------------------|-------------------------------------------------------|
| `TUNNEL_DOWN`          | IPsec SA is dead but DNS/internet look fine              | SSH the router: `journalctl -fu strongswan -n 100`    |
| `DDNS_DRIFT`           | `REMOTE_DDNS` no longer resolves to `REMOTE_WAN_IP`      | Log into your DDNS provider; update the A record      |
| `REMOTE_INTERNET_DOWN` | Remote site's public IP unreachable                      | Nothing to do — wait or call the remote site          |
| `ROUTER_UNREACHABLE`   | Tunnel down AND Mac can't SSH the router                 | Walk to the router; reboot if frozen                  |
| `DISAGREEMENT`         | Router says UP but Mac sees DOWN — Mac-side path issue   | `ping ROUTER_HOST`; restart networking; check VLAN    |
| `OUR_INTERNET_DOWN`    | Mac's own internet is down                               | No alert sent. Wait for our internet to recover       |

---

## Testing each failure mode manually

### Force `DDNS_DRIFT`

```bash
echo "10.99.99.99 $(awk -F'=' '/^REMOTE_DDNS=/ {print $2}' /opt/tunnel-monitor/config.env | tr -d '"')" \
    | sudo tee -a /etc/hosts
sudo dscacheutil -flushcache
for _ in 1 2 3; do sudo tunnel-check --check-now; sleep 2; done
tunnel-check                       # should show DDNS_DRIFT
# Cleanup:
sudo sed -i '' '/10.99.99.99/d' /etc/hosts
```

### Force `TUNNEL_DOWN`

Temporarily point `REMOTE_LAN_IP` at a black-hole IP:

```bash
sudo sed -i '' 's/^REMOTE_LAN_IP=.*/REMOTE_LAN_IP="10.255.255.255"/' /opt/tunnel-monitor/config.env
for _ in 1 2 3; do sudo tunnel-check --check-now; sleep 2; done
tunnel-check                       # should show TUNNEL_DOWN
# Cleanup: restore the real REMOTE_LAN_IP
```

### Force `ROUTER_UNREACHABLE`

Combine the `TUNNEL_DOWN` setup above with a bogus `ROUTER_HOST`:

```bash
sudo sed -i '' 's/^ROUTER_HOST=.*/ROUTER_HOST="10.255.255.254"/' /opt/tunnel-monitor/config.env
tunnel-check --ssh-test            # should FAIL
sudo tunnel-check --check-now
tunnel-check                       # diagnosis: ROUTER_UNREACHABLE
```

### Force `DISAGREEMENT`

Run `TUNNEL_DOWN` setup while leaving `ROUTER_HOST` pointing at a healthy
router (whose monitor sees `0:UP`).

### Recovery test

After any forced DOWN, undo the change and run `sudo tunnel-check
--check-now`. The `DOWN → UP` transition fires the recovery email + banner.

---

## Recovery from macOS updates

The plist at `/Library/LaunchDaemons/com.example.tunnel-monitor.plist` is
outside `/System/` so SIP doesn't touch it. Major OS upgrades sometimes
leave LaunchDaemons unloaded; if that happens:

```bash
sudo launchctl bootstrap system /Library/LaunchDaemons/com.example.tunnel-monitor.plist
sudo launchctl enable system/com.example.tunnel-monitor
sudo bash verify.sh
```

If anything else looks off, just re-run the installer — it's idempotent:

```bash
sudo bash install.sh
```

---

## Uninstall

```bash
sudo bash uninstall.sh           # interactive — asks before destroying config + state
sudo bash uninstall.sh --keep    # keep config.env + state.json
sudo bash uninstall.sh --yes     # remove everything, no prompts
```
