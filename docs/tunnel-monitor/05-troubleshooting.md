# Troubleshooting

[← Hub](README.md)

## Quick diagnostics

```bash
# Daemon loaded?
sudo launchctl print system/com.example.tunnel-monitor 2>&1 | head -20

# Last state
tunnel-check
jq . /opt/tunnel-monitor/state.json

# Recent log
tail -50 /opt/tunnel-monitor/monitor.log
```

From the app: **Force Check**, then read the popover checks and diagnosis line.

---

## Diagnosis codes (`state.json` → `diagnosis`)

Aligned with `monitor.sh` `compute_diagnosis` (first match wins).

| Code | Meaning | Email alert? |
|------|---------|--------------|
| `HEALTHY` | Tunnel ping OK | No (recovery if was DOWN) |
| `OUR_INTERNET_DOWN` | Mac has no internet (1.1.1.1) | No; counter frozen |
| `UDR7_UNREACHABLE` | Cannot SSH to gateway for dedup | Yes (Mac leads) |
| `DISAGREEMENT` | Gateway says `0:UP`, Mac sees tunnel down | Yes |
| `DDNS_DRIFT` | DDNS does not match `REMOTE_WAN_IP` | Yes after threshold |
| `REMOTE_INTERNET_DOWN` | Remote WAN ping fails, DNS OK | Yes after threshold |
| `TUNNEL_DOWN` | Tunnel down, WAN/DNS look OK | Yes after threshold |

Human labels in the GUI come from the same codes (e.g. **DDNS DRIFT — fix No-IP record**).

**Threshold:** `failure_count` must reach `FAILURE_THRESHOLD` (default 3) with `alert_state` UP before the first down alert. Each daemon cycle is five minutes.

---

## Email not sent but banner appeared

- **Dedup:** Gateway monitor already in DOWN state — email suppressed, banner still fires.
- **OUR_INTERNET_DOWN:** No email until internet returns.
- Check `monitor.log` for `DEDUP:` or `send-email` errors.
- Verify `SMTP_*` and app-specific password in `config.env`.

---

## No banner notifications

1. Run **Test Notify** from the app.
2. **System Settings → Notifications** — enable for Script Editor / osascript.
3. Confirm `NOTIFY_SOUND_*` names exist in `/System/Library/Sounds/`.

---

## SSH / dedup issues

| Symptom | Steps |
|---------|--------|
| Dedup always unreachable | **SSH Test**; run **Copy SSH Auth Cmd** once; verify `UDR7_HOST` is LAN IP of gateway |
| Permission denied | Key path `UDR7_KEY` mode `600`; pubkey on gateway `authorized_keys` |
| Wrong state path | Match `UDR7_STATE_PATH` to gateway monitor (`/data/tunnel-monitor/state`) |

---

## GUI-specific issues

### Menu popover freezes or crashes

- Do not use modal sheets/alerts inside the menu bar window (current builds use a separate Configuration window).
- Update to a build with async **Edit Config** / **Tail Log** (non-blocking Terminal launch).
- Ensure only one copy is running: `pkill -x TunnelMonitor` before reinstalling.

### Setup does nothing

- **Setup…** should open a window titled **Configuration** (not only the dashboard).
- Requires `AppWindowOpener` on the menu bar label; reinstall recent `Tunnel Monitor.app`.
- If the window opens behind other apps, check the Dock or use Mission Control.

### Edit Config crashes or hangs

- Fixed in builds that launch Terminal on a background thread and activate the app briefly.
- Rebuild: `bash build/build-app.sh`, adhoc-sign, copy to `/Applications/`.
- Expect popover caption: *Opening Terminal to edit config.env (admin password required).*

### App not visible after install

- Look for menu bar dot (right side).
- Enable **Show Dock icon** in Settings.
- `open "/Applications/Tunnel Monitor.app"`.

### High CPU / fan spin (older builds)

- Caused by menu bar ↔ `showMenuBar` feedback loop; update app.
- Verify with Activity Monitor: `TunnelMonitor` should idle near 0% CPU.

### `state.json` unreadable in UI

- Yellow **Monitor state unavailable** — file missing or permissions.
- Run `sudo bash install.sh` or pkg install; **Force Check** to create state.

---

## Launch failed from `/Applications` (error 162)

- Install unsigned builds need adhoc-signed bundle: `codesign --force --deep --sign - "/Applications/Tunnel Monitor.app"`.
- Or use release pkg built with `build/build-app.sh` (signs adhoc when no Developer ID).
- Clear quarantine if copied from download: `xattr -cr "/Applications/Tunnel Monitor.app"`.

---

## Related references

| Topic | Document |
|-------|----------|
| VPN-wide troubleshooting | [../troubleshooting.md](../troubleshooting.md) |
| OpenVPN migration | [../openvpn-site-to-site-migration.md](../openvpn-site-to-site-migration.md) |
| Architecture / dedup table | [02-architecture.md](02-architecture.md), [../architecture.md](../architecture.md) |
| Mac script reference | [../../mac/README.md](../../mac/README.md) |

---

## When to escalate

- Persistent `DDNS_DRIFT` after No-IP update — fix DNS at provider, then Force Check.
- `DISAGREEMENT` lasting multiple cycles — compare gateway vs Mac checks; possible asymmetric routing.
- Repeated `OUR_INTERNET_DOWN` — fix Mac WAN before tuning VPN.

For decision-tree style flows, see [../troubleshooting.md](../troubleshooting.md) (public) — not rewritten in this hub per scope.
