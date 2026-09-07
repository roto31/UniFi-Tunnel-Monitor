# Self-healing (UniFi gateway)

Opt-in recovery on the **gateway only**. The Mac monitor stays read-only: it
never restarts IPsec.

When the Route-Based tunnel interface is `DOWN` after a strongSwan restart,
three commands usually restore service: bring the tunnel interface up,
`ipsec reload`, then `ipsec up <conn-name>`. This engine runs that ladder
automatically, with hard rails so it cannot flap a production SA all day.

**Healing masks symptoms.** If it fires more than a few times a day, stop
enabling more aggressive steps and investigate WAN stability or firmware.
See [troubleshooting.md](troubleshooting.md#self-healing-didnt-recover-the-tunnel).

Default: **disabled** (`HEAL_ENABLED=false`). The monitor then behaves as it
did before this feature.

---

## What it does

On a healable diagnosis (`TUNNEL DOWN` / `TUNNEL_DOWN` only), `monitor.sh`
calls `/data/tunnel-monitor/heal.sh` **after** classification and **before**
the DOWN email. If the post-check ping to `REMOTE_LAN_IP` succeeds, the
gateway writes `0:UP` and does **not** send a DOWN alert (optional
self-healed email instead).

| Step | Precondition | Action | Post-check |
|------|--------------|--------|------------|
| 1 | `TUNNEL_IP` missing from `ipsec statusall` Listening IPs **and** the tunnel iface exists with `state DOWN` | `ip link set <iface> up` | `TUNNEL_IP` in Listening IPs |
| 2 | Step 1 ran, or Listening IP present but SA count is 0 | `ipsec reload`, wait `HEAL_SETTLE_SECONDS` | connection loaded |
| 3 | SA still not established | `ipsec up <conn-name>`, wait | `ESTABLISHED` **or** ping `REMOTE_LAN_IP` |
| 4 | Only if `HEAL_ALLOW_DAEMON_RESTART=true` and 1–3 failed | stale-PID-safe charon restart, wait, retry 1–3 once | ping `REMOTE_LAN_IP` |

The interface name is **discovered** (address on `TUNNEL_IP`, else `vti*` /
`ipsec*` / `tun*`). It is never hardcoded.

OpenVPN deployments: `heal.sh` returns exit `2` and does not run `ipsec`.

`swanctl` is not used.

---

## Rails (all on by default)

| Rail | Config | Default | Effect |
|------|--------|---------|--------|
| Opt-in | `HEAL_ENABLED` | `false` | No heal calls when false |
| Dry-run | `HEAL_DRY_RUN` | `false` | Log WOULD; no `ip`/`ipsec`/`pkill` |
| First failure | `HEAL_ON_FIRST_FAILURE` | `true` | Heal before the 15-minute threshold |
| Attempt budget | `HEAL_MAX_ATTEMPTS` | `3` | Consecutive failed cycles; then `heal exhausted` |
| Cooldown | `HEAL_COOLDOWN_MINUTES` | `30` | Minimum gap between live cycles |
| Daily cap | `HEAL_MAX_PER_DAY` | `6` | Then `heal capped — investigate root cause` |
| Local outage | (fixed) | — | If `ping 1.1.1.1` fails, skip heal |
| Command timeout | `HEAL_CMD_TIMEOUT` | `30` | `timeout` around every heal command |
| Ladder timeout | `HEAL_TOTAL_TIMEOUT` | `180` | Stop the cycle; systemd `TimeoutStartSec=240` |
| Daemon restart | `HEAL_ALLOW_DAEMON_RESTART` | `false` | Step 4 off until you opt in |

Budget **resets** on the first healthy check (`0:UP`).

Not healable (exit 2): `DDNS_DRIFT`, `REMOTE INTERNET DOWN`,
`OUR INTERNET DOWN`, `ROUTER_UNREACHABLE`, `DISAGREEMENT`.

---

## Rollout

1. Deploy scripts (`bash install.sh`). Leave `HEAL_ENABLED=false`.
2. Set `HEAL_DRY_RUN=true` and `HEAL_ENABLED=true` for a few days. Read
   `heal.log` and `tunnel-check --heal-dry-run`.
3. Set `HEAL_DRY_RUN=false`. Keep `HEAL_ALLOW_DAEMON_RESTART=false`.
4. Enable step 4 only if steps 1–3 repeatedly fail while the peer is up.

Fill `TUNNEL_IP` and `IPSEC_CONN_NAME` in `config.env` (see
[PLACEHOLDERS.md](../PLACEHOLDERS.md)).

---

## State and logs

Persistent (survives firmware; preserved on `install.sh` re-run):

| Path | Role |
|------|------|
| `/data/tunnel-monitor/heal-state` | `key=value` counters (attempts, cooldown, last result) |
| `/data/tunnel-monitor/heal.log` | Timestamped audit trail |
| `/data/tunnel-monitor/heal-last.txt` | Last cycle summary (copied into DOWN / self-healed mail) |

`heal-state` fields: `attempts_today`, `attempts_day`, `consecutive_fails`,
`last_cycle_epoch`, `last_result`, `cooldown_until_epoch`,
`exhausted_alerted`, `capped_alerted`.

### Reading `heal.log`

Each cycle logs start, discovered iface, each step (SKIPPED / RUN / exit /
post-check), and recovered vs failed. Correlate with
`journalctl -u tunnel-monitor.service`.

---

## CLI

```bash
tunnel-check --heal-status
tunnel-check --heal-dry-run
tunnel-check --heal-now      # ignores cooldown; still respects daily cap + 1.1.1.1
tunnel-check --heal-log
tunnel-check --heal-reset
```

Or call `heal.sh` directly under `/data/tunnel-monitor/`.

---

## Disable in a hurry

```bash
sed -i 's/^HEAL_ENABLED=.*/HEAL_ENABLED="false"/' /data/tunnel-monitor/config.env
```

No timer restart required; the next `monitor.sh` tick reads config.

---

## Why gateway-only

The Mac is a LAN client. It can ping and SSH-read `N:UP`/`N:DOWN`. Restarting
charon from a workstation would race the gateway monitor, break UniFi's own
IPsec hooks, and cannot see `vti` admin-state. Recovery belongs next to
`ipsec`.
