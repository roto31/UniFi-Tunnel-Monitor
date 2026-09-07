# UniFi gateway side — Tunnel Monitor (Linux + systemd)

A lightweight bash + systemd monitor that watches a site-to-site IPsec VPN
from the **gateway perspective** and sends authenticated SMTP alerts when
the tunnel goes down or recovers. Originally written for the UniFi Dream
Router 7 (UDR7) but works on any UniFi gateway that runs Linux + systemd
(UDM, UDM-Pro, UDM-SE, UDR, UDR7) and any other Debian-derived system with
the same toolchain.

This is the **UniFi gateway side**. The matching macOS side lives in
[`../mac/`](../mac/).

---

## What it does

Every 5 minutes a systemd timer runs `monitor.sh`, which:

1. Pings `REMOTE_LAN_IP` over the tunnel (the remote site's LAN gateway).
2. Pings `REMOTE_WAN_IP` directly (remote public IP) — disambiguates "tunnel
   down" from "remote site offline".
3. Tracks consecutive failures in a single-line state file
   `/data/tunnel-monitor/state` formatted as `N:UP` / `N:DOWN`.
4. After `FAILURE_THRESHOLD` consecutive failures (default 3 → ~15 min),
   sends a single DOWN alert email with diagnostics.
5. When the tunnel recovers after being marked DOWN, sends a recovery email.
6. The alert email body includes:
   - DNS resolution of `REMOTE_DDNS` and a match/mismatch verdict.
   - Reachability tests (tunnel ping, remote WAN ping, our sanity ping).
   - `ipsec statusall` output (SA states).
   - Last 15 lines of `journalctl` containing `charon` (strongSwan log).
   - A diagnosis in the subject: `TUNNEL DOWN`, `DDNS DRIFT — fix your
     DDNS record`, or `REMOTE INTERNET DOWN`.

The state file (`N:UP` / `N:DOWN`) is what the Mac side reads over SSH to
de-duplicate alerts.

---

## Prerequisites

- A UniFi gateway running Linux + systemd. The persistent install path is
  `/data/tunnel-monitor/` — UniFi's writable partition that **survives
  firmware updates**. `/etc/systemd/system/` does NOT always survive; the
  installer is designed to be safely re-run after a firmware update.
- Root SSH access to the gateway (UniFi's factory default).
- A site-to-site IPsec VPN already configured and (normally) up.
- `bash`, `curl`, `dig`, `ping`, `ipsec`, `systemctl`, `journalctl`,
  `logger`, `mktemp` — all present on stock UniFi firmware.
- An SMTP account capable of authenticated submission on port 587
  (iCloud, Gmail, Fastmail, etc.).

---

## Install

From your workstation, copy the sanitized `unifi/` folder to the gateway:

```bash
scp -r unifi/ root@<YOUR_ROUTER_LAN_IP>:/root/tunnel-monitor-src
ssh root@<YOUR_ROUTER_LAN_IP>
cd /root/tunnel-monitor-src
bash install.sh
```

The installer:

1. Copies `monitor.sh`, `send-email.sh`, `tunnel-check`, `heal.sh` into
   `/data/tunnel-monitor/` with `0755` / `0700` / `0755` / `0755` modes.
2. Drops `config.env.template` as `/data/tunnel-monitor/config.env`
   (mode `0600`) **only if** `config.env` is missing — re-runs preserve
   your edited config.
3. Initializes `/data/tunnel-monitor/state` to `0:UP` if missing.
   Initializes `heal-state` and `heal.log` if missing; never overwrites them.
4. Installs `tunnel-monitor.service` and `tunnel-monitor.timer` into
   `/etc/systemd/system/`.
5. Symlinks `/data/tunnel-monitor/tunnel-check` to `/usr/local/bin/tunnel-check`.
6. Runs `systemctl daemon-reload` and `systemctl enable --now
   tunnel-monitor.timer`.

After install, edit the config:

```bash
vi /data/tunnel-monitor/config.env
```

Replace every `REPLACE_WITH_*` value (see [`../PLACEHOLDERS.md`](../PLACEHOLDERS.md)).
Then validate:

```bash
tunnel-check --test-email                 # confirm SMTP plumbing
systemctl start tunnel-monitor.service    # trigger an immediate check
journalctl -u tunnel-monitor.service --no-pager -n 30
```

---

## Configuration

All values live in `/data/tunnel-monitor/config.env` (chmod 0600). Required:

| Var                  | What it is                                                 |
|----------------------|------------------------------------------------------------|
| `SMTP_SERVER` `SMTP_PORT` | Submission server + port (typically `587` STARTTLS)   |
| `SMTP_USER`          | Authenticated SMTP username (usually full email address)   |
| `SMTP_PASSWORD`      | App-specific password (NOT your account password)          |
| `ALERT_FROM`         | "From" header (must equal `SMTP_USER` on most providers)   |
| `ALERT_TO`           | Where to send alerts                                       |
| `REMOTE_LAN_IP`      | LAN gateway IP at the remote site, reachable over tunnel   |
| `REMOTE_WAN_IP`      | Remote site's expected public IP                           |
| `REMOTE_DDNS`        | DDNS hostname that should resolve to `REMOTE_WAN_IP`       |

Optional tuning:

| Var                  | Default | Purpose                                          |
|----------------------|---------|--------------------------------------------------|
| `FAILURE_THRESHOLD`  | `3`     | Consecutive failures before alerting             |
| `PING_COUNT`         | `3`     | Pings per check                                  |
| `PING_TIMEOUT`       | `2`     | Seconds before each ping is considered failed    |
| `SUBJECT_PREFIX`     | `""`    | Optional prefix on email subjects (e.g. `[ROUTER]`) |
| `HEAL_ENABLED`       | `false` | Opt-in self-healing ([docs/self-healing.md](../docs/self-healing.md)) |
| `TUNNEL_IP`          | placeholder | Tunnel iface address (heal ladder) |
| `IPSEC_CONN_NAME`    | placeholder | `ipsec up` connection name |

---

## CLI cheat sheet

| Command                                  | What it does                                  |
|------------------------------------------|-----------------------------------------------|
| `tunnel-check`                           | One-shot status dump (DNS, pings, IPsec, timer) |
| `tunnel-check --test-email`              | Send a test email through the alert pipeline  |
| `tunnel-check --reset`                   | Clear failure counter (after manual fix)      |
| `tunnel-check --tail`                    | Follow live monitor logs via `journalctl -f`  |
| `tunnel-check --history`                 | Last 50 monitor runs                          |
| `tunnel-check --heal-status`             | Heal counters, cooldown, last cycle           |
| `tunnel-check --heal-dry-run`            | Print recovery ladder; change nothing         |
| `tunnel-check --heal-now`                | Force one heal cycle (ignores cooldown)       |
| `tunnel-check --heal-reset`              | Clear heal counters                           |
| `tunnel-check --heal-log`                | Tail `/data/tunnel-monitor/heal.log`          |
| `systemctl start tunnel-monitor.service` | Force an immediate check                      |
| `systemctl list-timers tunnel-monitor.timer` | When the next scheduled run will fire     |

---

## Script reference

### `monitor.sh` — health check + state machine + alert dispatch

Behavioural facts (cite by line; see file for full code):

- Uses `set -u` (not `-euo pipefail`) so unset variables fail loudly but a
  failed individual command does not abort the run. The script is expected
  to "always" finish so the next timer tick can proceed.
- Reads `/data/tunnel-monitor/state` as `N:UP` or `N:DOWN`. Defaults to
  `0:UP` if missing (`read_state()`).
- `check_ping()` uses `ping -c "$PING_COUNT" -W "$PING_TIMEOUT"` (Linux
  semantics — `-W` is seconds per packet, not ms as on macOS).
- `resolve_ddns()` runs `dig +short +time=3 +tries=1 "$REMOTE_DDNS" @1.1.1.1`.
- `check_ipsec()` greps `ipsec statusall` for the literal `ESTABLISHED`.
- `build_diagnostics()` emits a heredoc with topology, DNS verdict,
  per-target ping verdict, `ipsec statusall` excerpt, and last 15
  charon-tagged `journalctl` lines — included verbatim in alert bodies.
- State machine: `UP → UP` no-op; `UP → DOWN` increments counter; when
  `counter >= FAILURE_THRESHOLD && state == UP` it diagnoses and sends the
  first alert, then transitions to `DOWN`. While `DOWN`, no further alerts.
  On `DOWN → UP` it sends a recovery email and resets to `0:UP`.
- Subject diagnosis logic: if remote WAN is unreachable → `REMOTE INTERNET
  DOWN`; else if DDNS resolution drifted → `DDNS DRIFT — fix your DDNS
  record`; else → `TUNNEL DOWN`.

### `send-email.sh` — authenticated SMTP submission

- Usage: `send-email.sh "Subject" "Body text"` (note: body is a literal
  string here, not a file path — different from the Mac side).
- Requires `SMTP_USER`, `SMTP_PASSWORD`, `ALERT_FROM`, `ALERT_TO`; aborts
  with bash's `:?` parameter expansion if any are unset.
- Defaults: `SMTP_SERVER=smtp.mail.me.com`, `SMTP_PORT=587`.
- Writes an RFC822-compliant message to `mktemp`, then submits via
  `curl --silent --show-error --ssl-reqd --url smtp://...` with
  `--connect-timeout 15 --max-time 30`.
- Logs success/failure via `logger -t tunnel-monitor`.
- Exits with curl's exit code on submission failure; 0 on success.

### `tunnel-check` — operator CLI

- `tunnel-check` (no args): prints the state file, runs ad-hoc DNS + ping
  + ipsec checks, shows next timer firing.
- `--test-email`: sends `"TEST — Site-to-site Tunnel Monitor"` to confirm
  SMTP plumbing.
- `--reset`: writes `0:UP` to the state file.
- `--tail`: `journalctl -u tunnel-monitor.service -f`.
- `--history`: `journalctl -u tunnel-monitor.service --no-pager -n 50`.

### `tunnel-monitor.service` / `tunnel-monitor.timer`

- `.service` is `Type=oneshot`, runs `monitor.sh` as `root`, with
  `TimeoutStartSec=120` so a flaky tunnel never hangs systemd.
- `.timer` fires `OnBootSec=2min` then `OnUnitActiveSec=5min`, with
  `Persistent=true` so a missed run while the gateway was offline fires on
  next boot.
- `.service` `TimeoutStartSec=240` so a full heal ladder (`HEAL_TOTAL_TIMEOUT=180`) plus diagnostics can finish.

### `heal.sh` — optional IPsec recovery ladder

See [../docs/self-healing.md](../docs/self-healing.md). Defaults off. Never
runs for DDNS drift, remote-internet-down, or OpenVPN.

---

## Alert response runbook

The diagnosis is in the subject. Three things you'll see:

### `TUNNEL DOWN`

DNS resolves correctly and the remote public IP is reachable, but the IPsec
SA is dead. Usually strongSwan config drift, a crypto mismatch after a
firmware update, or NAT-T state corruption.

```bash
ssh root@<gateway>
journalctl -fu strongswan -n 100
ipsec statusall
ipsec restart            # if the SA is wedged
```

In the UniFi UI: Settings → VPN → site-to-site → toggle the tunnel.

### `DDNS DRIFT — fix your DDNS record`

`REMOTE_DDNS` no longer resolves to `REMOTE_WAN_IP`. The remote site's
ISP probably rotated their public IP and your DDNS record is stale.

1. Find the remote site's new public IP (have them visit
   <https://whatismyip.com> or check their ISP modem's admin UI).
2. Log into your DDNS provider and update the A record.
3. The tunnel recovers on the next scheduled check.

### `REMOTE INTERNET DOWN`

The remote site's public IP is unreachable from the gateway. Their
internet is offline. Nothing to do but wait or call them.

---

## Recovery from firmware updates

UniFi firmware updates can wipe `/etc/systemd/system/`. The persistent
files in `/data/tunnel-monitor/` survive, but the systemd units and the
`/usr/local/bin/tunnel-check` symlink may not.

After a firmware update, just re-run the installer from wherever you
saved the source:

```bash
cd /root/tunnel-monitor-src
bash install.sh
```

It preserves your existing `config.env`, `state`, `heal-state`, and
`heal.log` so you won't have to re-enter the SMTP password or lose heal
counters.

---

## File layout

```
/data/tunnel-monitor/               # Persistent — survives firmware updates
├── monitor.sh                       # health check + state machine
├── send-email.sh                    # authenticated SMTP submission via curl
├── tunnel-check                     # CLI tool (symlinked to /usr/local/bin)
├── heal.sh                          # optional IPsec recovery ladder
├── config.env                       # SMTP creds + tunable params (chmod 0600)
├── state                            # "N:UP" or "N:DOWN" — internal state
├── heal-state                       # self-heal counters (key=value)
└── heal.log                         # self-heal audit log

/etc/systemd/system/                 # Volatile — may need reinstall
├── tunnel-monitor.service
└── tunnel-monitor.timer
```

---

## Sanitization notes for forks

This release replaces every environment-specific value (IPs, hostnames,
emails, identifiers) with `REPLACE_WITH_*` placeholders or RFC-5737
documentation IPs. See [`../PLACEHOLDERS.md`](../PLACEHOLDERS.md) for the
full list and recommended values.

Specifically:

- The fallback defaults in `monitor.sh` (`192.0.2.1`, `198.51.100.1`,
  `remote.example.com`) are RFC-5737 / RFC-2606 reserved values that will
  not connect to a real network. They exist only to keep the script
  parseable if config.env is missing — replace via config.env, not by
  editing the defaults.
- Install paths (`/data/tunnel-monitor/`, `/etc/systemd/system/`) are UniFi
  conventions and are not placeholders.
- `1.1.1.1` (DNS resolver) and `8.8.8.8` (sanity ping target on the Mac
  side) are public infrastructure and not placeholders.
