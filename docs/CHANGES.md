# Changes log (operator)

## 2026-09-06 — Gateway self-healing

**What was done:** Opt-in IPsec recovery ladder on the UniFi gateway (`heal.sh`), wired into `monitor.sh` between classify and alert. Disabled by default. systemd `TimeoutStartSec=240`. Docs + `unifi/verify.sh`.

**Files changed:** `unifi/heal.sh` (new), `unifi/monitor.sh`, `unifi/tunnel-check`, `unifi/config.env.template`, `unifi/install.sh`, `unifi/verify.sh` (new), `unifi/tunnel-monitor.service`, `unifi/README.md`, `docs/self-healing.md`, `docs/troubleshooting.md`, `docs/architecture.md`, `docs/README.md`, `README.md`, `PLACEHOLDERS.md`, `mac/CHANGELOG.md`.

**Verified by:** `bash -n` on gateway scripts; `heal.sh --help`; `heal.sh --dry-run TUNNEL_DOWN` (no `/data` writes); `heal.sh --status` exit 0; `heal.sh --dry-run DDNS_DRIFT` exit 2.

**Rollback:** `HEAL_ENABLED="false"` or revert the commit.
