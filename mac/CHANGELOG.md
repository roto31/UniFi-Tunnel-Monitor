# Changelog — Tunnel Monitor.app (public / sanitized)

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions: [SemVer](https://semver.org/spec/v2.0.0.html).
Bundled data: [`datasets/bundle-manifest.json`](../datasets/bundle-manifest.json).

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
