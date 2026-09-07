# Changes log (operator)

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
