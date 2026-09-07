# Changelog — Tunnel Monitor.app (public / sanitized)

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions: [SemVer](https://semver.org/spec/v2.0.0.html).
Bundled data: [`datasets/bundle-manifest.json`](../datasets/bundle-manifest.json).

## Documentation

- [Docs index](../docs/README.md)
- [Troubleshooting](../docs/troubleshooting.md)

## [Unreleased]

## [1.3.0] - 2026-09-06

### Added

- UniFi gateway **self-healing** (`unifi/heal.sh`): opt-in IPsec recovery ladder before DOWN alerts, with attempt budget, cooldown, daily cap, and no-heal on local outage — see [Self-healing](../docs/self-healing.md).

### Docs

- [Self-healing](../docs/self-healing.md) and troubleshooting section [Self-healing didn't recover the tunnel](../docs/troubleshooting.md#self-healing-didnt-recover-the-tunnel).

### Build / CI

- Release workflow imports a minimal Developer ID `.p12` into an ephemeral keychain (plus Apple Developer ID G2 CA), isolates the search list from login (LaunchAgent `errSecInternalComponent`), and restores login.keychain after the job. systemd `TimeoutStartSec=240` so a full heal ladder can finish.

## [1.2.1] - 2026-09-06

### Security

- Signed **Developer ID** `.app` + `.pkg` and Apple notarization (stapled), using the App Store Connect API key on the M4 GitHub Actions runner.

### Build / CI

- Release workflow writes `ASC_KEY_P8_*` for `notarytool` and uses host keychain Developer ID identities when no `.p12` secret is present.

## [1.2.0] - 2026-09-06

### Docs

- [Troubleshooting](../docs/troubleshooting.md): five real-world IPsec failure modes — vti interface DOWN / stale charon PIDs, `NO_PROPOSAL_CHOSEN` after remote reboot (crypto + Auth ID drift), ISP modem DMZ vs port-forward vs Advanced Security, `ipsec`-only firmware note, and compound-failure sequencing.

### Build / CI

- Fix `concurrency` placement in `.github/workflows/release.yml` so tagged pkg builds run on the M4 runner.
- Pin release Actions to resolvable SHAs (`checkout` v4.2.2, `upload-artifact` v4.6.0, `action-gh-release` v2.6.2) and select Xcode without `sudo`.

## [1.1.0] - 2026-05-31

### Code

- Liquid Glass menu bar UI (macOS 26+ with accessibility fallback).
- Automated Liquid Glass app icon (`mac/generate-app-icon.sh`, `build/generate-liquid-glass-icon.sh`).
- Published GUI sources under `mac/app/TunnelMonitor/`.

### Data

- `dataRevision`: `wizard-fields` public-v1 (sanitized), `liquid-glass-v1` icon + `Assets.car`.

## [1.0.0] - 2026-05-12

### Code

- First public SwiftUI menu bar app (`com.example.tunnel.monitor`).
- Sanitized payload (`ssh-router-state.sh`, `com.example.tunnel-monitor.plist`).
- SwiftBar plugin and install/verify scripts under `mac/`.

### Data

- `dataRevision`: `wizard-fields` public-v1, legacy `AppIcon.icns`.
