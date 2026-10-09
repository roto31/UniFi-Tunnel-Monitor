# Changes log (operator)

## 2026-10-08 — Spoke policy checker 1.5.0

**What was done:** The Mac can install a checker on the spoke gateway. The checker reads the gateway policy-routing mark for `SPOKE_POLICY_SOURCE_CIDR` and writes `/data/tunnel-monitor/policy-state`. Advisories stay UI-only. Diagnosis and email are unchanged.

**Files changed:** `mac/payload/opt/tunnel-monitor/spoke-policy-check.sh`, `tunnel-check`, `config.env.template`, `mac/install.sh`, app Actions and status menu, `wizard-fields.json`, `mac/CHANGELOG.md`, `datasets/bundle-manifest.json`, `PLACEHOLDERS.md`, usage/setup/troubleshooting/implementation/spoke docs, `.release-notes-v1.5.0.md`.

**Commands run:** `bash -n` on the new scripts; `spoke-policy-check.sh --self-test`; `tunnel-check --spoke-install-checker` on the live spoke; `VERSION=1.5.0 bash build/build-app.sh`.

**Verified by:** self-test, spoke SSH test showing `0:UP` when the route is present, menu card after a daemon kick.

**Rollback:** On the spoke, `systemctl disable --now tunnel-monitor-policy.timer` and remove `/data/tunnel-monitor/policy-state`. Set `SPOKE_POLICY_ENABLED="false"` to hide the card. Reinstall the 1.4.0 app.

## 2026-10-08 — Spoke policy-route visibility 1.4.0

**What was done:** Opt-in Mac check of the spoke policy-state file and observed public IP. UI advisories and one banner per transition. No email and no diagnosis change. Gateway diagnostics print OpenVPN status when IPsec has no SAs. Private install label stays `com.ruter.tunnel-monitor`; public Info.plist stays sanitized.

**Files changed:** `mac/payload/opt/tunnel-monitor/monitor.sh`, `ssh-spoke-state.sh`, `tunnel-check`, `config.env.template`, `mac/install.sh`, `mac/verify.sh`, `mac/app/TunnelMonitor` sources and Resources, `unifi/monitor.sh`, `mac/CHANGELOG.md`, `datasets/bundle-manifest.json`, `PLACEHOLDERS.md`, `verify-1.4.0.sh`.

**Commands run:** `/bin/bash -n` on payload scripts; `bash -n unifi/monitor.sh`; `swift test`; `VERSION=1.4.0 bash build/build-app.sh`; `sudo bash mac/install.sh` (config.env and state.json preserved).

**Verified by:** `verify-1.4.0.sh`.

**Rollback:** Restore `/opt/tunnel-monitor` from `~/UniFi-Backups/tunnel-monitor-pre-1.4.0-*` and reinstall the 1.3.1 app. Set `SPOKE_POLICY_ENABLED="false"`.

## 2026-09-06 — Mac SSH Test elevation + ROUTER_/UDR7_ aliases

**What was done:** In-app SSH Test runs `tunnel-check --ssh-test` as root. `ssh-router-state.sh` accepts wizard `UDR7_*` keys. Wizard Save emits both key families. Tagged **v1.3.1** for a signed+notarized pkg (cannot reuse 1.3.0).

**Files changed:** `mac/app/.../Actions.swift`, `ConfigEnvWriter.swift`, `WizardFieldModels.swift`, `mac/payload/opt/tunnel-monitor/ssh-router-state.sh`, `mac/payload/opt/tunnel-monitor/tunnel-check`, Linux payload siblings, `mac/CHANGELOG.md`, `docs/troubleshooting.md`, `mac/README.md`, `datasets/bundle-manifest.json`.

**Verified by:** `bash -n` on patched scripts; `sudo tunnel-check --ssh-test` after install of 1.3.1 pkg.

**Rollback:** Reinstall `Tunnel-Monitor-1.3.0.pkg`. Keep `ROUTER_*` aliases in `config.env` if staying on 1.3.0.

## 2026-09-06 — Gateway self-healing

**What was done:** Opt-in IPsec recovery ladder on the UniFi gateway (`heal.sh`), wired into `monitor.sh` between classify and alert. Disabled by default. systemd `TimeoutStartSec=240`. Docs + `unifi/verify.sh`.

**Files changed:** `unifi/heal.sh` (new), `unifi/monitor.sh`, `unifi/tunnel-check`, `unifi/config.env.template`, `unifi/install.sh`, `unifi/verify.sh` (new), `unifi/tunnel-monitor.service`, `unifi/README.md`, `docs/self-healing.md`, `docs/troubleshooting.md`, `docs/architecture.md`, `docs/README.md`, `README.md`, `PLACEHOLDERS.md`, `mac/CHANGELOG.md`.

**Verified by:** `bash -n` on gateway scripts; `heal.sh --help`; `heal.sh --dry-run TUNNEL_DOWN` (no `/data` writes); `heal.sh --status` exit 0; `heal.sh --dry-run DDNS_DRIFT` exit 2.

**Rollback:** `HEAL_ENABLED="false"` or revert the commit.
