# Placeholders Reference

Every value below appears as a placeholder somewhere in the repo. Replace it
with a real value from your environment before deploying.

Placeholders are clustered by where they appear. Most live in
`config.env.template` (which the installer copies to `config.env`) but a few
live in identifiers and paths.

---

## 1. Configuration values (in both `mac/payload/opt/tunnel-monitor/config.env.template` and `unifi/config.env.template`)

| Placeholder                              | What to set it to                                           | Example value                                    |
|------------------------------------------|-------------------------------------------------------------|--------------------------------------------------|
| `REPLACE_WITH_REMOTE_LAN_GATEWAY_IP`     | LAN gateway IP at your remote site, reachable over the tunnel | `192.168.10.1`                                 |
| `REPLACE_WITH_REMOTE_PUBLIC_IP`          | Static / expected public IP of your remote site             | `203.0.113.42`                                   |
| `REPLACE_WITH_REMOTE_DDNS_HOSTNAME`      | DDNS hostname pointing at your remote site's public IP      | `remote-site.example-ddns.com`                   |
| `REPLACE_WITH_SMTP_SERVER`               | SMTP submission hostname                                    | `smtp.mail.me.com` (iCloud), `smtp.gmail.com`    |
| `REPLACE_WITH_SMTP_PORT`                 | SMTP submission port (STARTTLS)                             | `587`                                            |
| `REPLACE_WITH_SMTP_USERNAME`             | Full email used to authenticate                             | `you@icloud.com`                                 |
| `REPLACE_WITH_APP_SPECIFIC_PASSWORD`     | App-specific password (NOT your account password)           | (16-char string from provider)                   |
| `REPLACE_WITH_ALERT_FROM_ADDRESS`        | "From" header on alerts (must equal `SMTP_USERNAME` on iCloud) | `you@icloud.com`                              |
| `REPLACE_WITH_ALERT_TO_ADDRESS`          | Where alerts are sent (your own inbox, usually)             | `you@icloud.com`                                 |
| `REPLACE_WITH_SUBJECT_PREFIX`            | Identifies which vantage point sent the alert               | `[MAC]`, `[ROUTER]`, `[SPOKE-MAC]`             |

## 1b. Spoke-side (inverted topology)

Used in [`spoke/udm/config.env.template`](spoke/udm/config.env.template) and [`spoke/remote-mac/config.env.template`](spoke/remote-mac/config.env.template). On the **spoke**, `REMOTE_*` points at the **hub**.

| Placeholder                              | What to set it to                                           | Example value                                    |
|------------------------------------------|-------------------------------------------------------------|--------------------------------------------------|
| `REPLACE_WITH_HUB_LAN_GATEWAY_IP`        | Hub LAN gateway, reachable over the tunnel from spoke       | `192.0.2.1` (RFC 5737 doc block)                 |
| `REPLACE_WITH_HUB_PUBLIC_IP`             | Hub primary public WAN IP                                   | `203.0.113.10`                                   |
| `REPLACE_WITH_HUB_DDNS_HOSTNAME`         | DDNS hostname the spoke OpenVPN tunnel dials                | `hub.example-ddns.test`                          |
| `REPLACE_WITH_SPOKE_GATEWAY_LAN_IP`      | Spoke UniFi gateway LAN IP (SSH dedup target on spoke Mac)  | `198.51.100.1`                                   |

## 1c. WAN Guard (hub dual-WAN only)

Append to hub `/data/tunnel-monitor/config.env` via [`unifi/wan-guard/config-additions.env`](unifi/wan-guard/config-additions.env).

| Placeholder                              | What to set it to                                           | Example value                                    |
|------------------------------------------|-------------------------------------------------------------|--------------------------------------------------|
| `REPLACE_WITH_WAN_GUARD_INTERFACE`       | Linux interface for **primary public WAN** (`ip -4 addr`)   | `eth2`                                           |
| `REPLACE_WITH_HUB_DDNS_HOSTNAME`         | Same hostname remote site dials for OpenVPN                 | `hub.example-ddns.test`                          |
| `REPLACE_WITH_NOIP_USERNAME`             | DDNS provider account username                              | `your-ddns-user`                                 |
| `REPLACE_WITH_NOIP_PASSWORD`             | DDNS provider password or API token                           | (from provider dashboard)                        |

## 2. Mac-side only

| Placeholder                              | What to set it to                                           | Example value                                    |
|------------------------------------------|-------------------------------------------------------------|--------------------------------------------------|
| `REPLACE_WITH_ROUTER_LAN_IP`             | LAN IP of the UniFi gateway (so the Mac can SSH to it)      | `192.168.1.1`                                    |
| `REPLACE_WITH_ROUTER_SSH_USER`           | SSH user on the gateway                                     | `root` (UniFi default)                           |
| `com.example.tunnel-monitor`             | Reverse-DNS bundle label for the LaunchDaemon — pick anything unique to you | `com.yourusername.tunnel-monitor` |
| `com.example.tunnel.monitor`             | Bundle ID for the menu bar app under `mac/app/` (must differ from your daemon label string if you prefer) | `com.yourusername.tunnelmonitor` |

These appear in:
- `mac/payload/LaunchDaemons/com.example.tunnel-monitor.plist` (label inside the file **and** the filename)
- `mac/payload/opt/tunnel-monitor/config.env.template` (`ROUTER_HOST`, `ROUTER_USER`)
- Several `tunnel-check` and `install.sh` calls to `launchctl ... system/com.example.tunnel-monitor`
- `mac/app/TunnelMonitor/Resources/Info.plist` — `CFBundleIdentifier`, `TMLaunchDaemonLabel`, and UI strings (`TMDedupSectionTitle`, `TMStatusBannerTitle`)
- `mac/app/TunnelMonitor/Resources/wizard-fields.json` — setup wizard keys (`ROUTER_*`, `REPLACE_WITH_*` defaults)

If you rename the plist, search-and-replace `com.example.tunnel-monitor`
across the `mac/` subtree (3 files) before installing.

## 3. UniFi-side only

There are no UniFi-only placeholders beyond the shared config values. The
UniFi monitor doesn't SSH to anything; it relies on the local `ipsec` CLI
and `journalctl` for diagnostics.

## 4. What is NOT a placeholder

The following appear in the repo but are NOT placeholders — they are
either standardized values, documented protocol details, or sensible
defaults the user typically should not change:

| Value | Where | Why it's not a placeholder |
|-------|-------|----------------------------|
| `/opt/tunnel-monitor/` | Mac install path | Standard Unix convention for optional software, no PII |
| `/data/tunnel-monitor/` | UniFi install path | UniFi's persistent partition (survives firmware updates) |
| `/usr/local/bin/tunnel-check` | CLI symlink | Standard PATH location |
| `/Library/LaunchDaemons/` | macOS LaunchDaemon directory | Apple-defined |
| `/etc/systemd/system/` | systemd unit directory | Linux-defined |
| `1.1.1.1`, `8.8.8.8` | DNS / sanity-ping targets | Public, documented resolvers |
| `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` | Documentation examples in README | IETF RFC 5737 reserved for docs |
| `300` (`StartInterval` in plist) | 5-minute check cadence | Same as the UniFi side; do not poll faster than 30 s |
| `Glass`, `Hero` | Default notification sounds | macOS built-in sound names |

---

## 5. Uncertainty notes

The values below were **observed in the source environment** but are
**borderline** — they might be considered sensitive in some contexts. They
have been sanitized to placeholders in this Public release. Re-check before
publishing your own fork:

- **SMTP server hostnames.** `smtp.mail.me.com` (iCloud), `smtp.gmail.com`, etc.
  are public documented endpoints — not credentials. The Public release
  uses `REPLACE_WITH_SMTP_SERVER` so the template is provider-agnostic, but
  you can hard-code your provider's server if you don't mind it being in
  your fork.
- **The LaunchDaemon reverse-DNS label.** `com.example.tunnel-monitor` is a
  placeholder; pick your own. There is no central registry for these — any
  unique reverse-DNS string is fine.
- **DDNS provider name.** The original deployment used No-IP. The sanitized
  README and runbook refer generically to "your DDNS provider"; if your
  provider name leaks any context you'd rather not share (e.g. business
  name in account), redact accordingly.
- **Path conventions.** `/data/tunnel-monitor/` is specific to UniFi gateway
  storage layout. If you're adapting this for a non-UniFi router, change
  the path in `unifi/install.sh`, `unifi/monitor.sh`, `unifi/send-email.sh`,
  `unifi/tunnel-check`, and the `ROUTER_STATE_PATH` value in
  `mac/payload/opt/tunnel-monitor/config.env.template`.

---

## 6. Quick replace recipe

If you want to do all the find-and-replace at once, run from the repo root:

```bash
# Edit just the two config templates first — most placeholders live there.
$EDITOR mac/payload/opt/tunnel-monitor/config.env.template
$EDITOR unifi/config.env.template

# Optional: rename the plist label everywhere in the mac/ subtree
OLD="com.example.tunnel-monitor"
NEW="com.yourusername.tunnel-monitor"
find mac -type f \( -name '*.sh' -o -name '*.plist' -o -name 'tunnel-check' -o -name '*.md' \) \
    -exec sed -i '' "s/${OLD}/${NEW}/g" {} +
mv "mac/payload/LaunchDaemons/${OLD}.plist" "mac/payload/LaunchDaemons/${NEW}.plist"
```

(Use `sed -i` without the empty `''` arg on GNU sed; the example above is
BSD-flavour for macOS.)
