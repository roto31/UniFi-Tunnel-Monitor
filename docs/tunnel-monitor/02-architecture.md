# Architecture & system diagrams

[← Hub](README.md)

This page describes the **Mac Studio / LAN-client** stack centered on Tunnel Monitor.app and `/opt/tunnel-monitor/`. For gateway-side monitors, WAN Guard, and multi-site topology, see [../architecture.md](../architecture.md).

---

## System component diagram

```mermaid
flowchart TB
  subgraph daemon [LaunchDaemon every 5 min]
    monitorSh[monitor.sh]
    stateJson[(state.json)]
    sendEmail[send-email.sh]
    notifySh[notify.sh]
    sshDedup[ssh-router-state.sh]
    monitorSh --> stateJson
    monitorSh --> sendEmail
    monitorSh --> notifySh
    monitorSh --> sshDedup
  end

  subgraph gui [Tunnel Monitor.app read-only UI]
    menuBar[MenuBarExtra popover]
    dashboard[Dashboard window]
    setupWin[Configuration window]
    monitorState[MonitorState polls state.json]
    actions[Actions CLI and osascript]
    menuBar --> monitorState
    dashboard --> monitorState
    setupWin --> configEnv["config.env"]
    menuBar --> actions
  end

  subgraph remote [Remote site]
    remoteGW[REMOTE_LAN_IP over tunnel]
  end

  subgraph hub [Local UniFi gateway optional]
    udr7State["gateway dedup state"]
  end

  SMTP[SMTP provider]
  monitorSh -->|ping| remoteGW
  sshDedup -->|SSH cat| udr7State
  sendEmail --> SMTP
  monitorState --> stateJson
  actions -->|kickstart| monitorSh
```

---

## Data flow (one check cycle)

```mermaid
sequenceDiagram
  participant LD as launchd
  participant M as monitor.sh
  participant S as state.json
  participant E as send-email.sh
  participant N as notify.sh
  participant App as Tunnel Monitor.app

  LD->>M: every 300s
  M->>M: ping REMOTE_LAN_IP REMOTE_WAN_IP 1.1.1.1
  M->>M: dig REMOTE_DDNS compare REMOTE_WAN_IP
  M->>M: SSH read gateway dedup state
  M->>M: compute_diagnosis
  M->>S: atomic write .tmp then mv
  alt failures >= FAILURE_THRESHOLD and alert_state was UP
    M->>E: alert email unless dedup suppresses
    M->>N: banner Tunnel DOWN
  end
  loop every 5 to 30s
    App->>S: read JSON
    App->>App: StatusPresentation traffic light
  end
```

---

## Alert decision flow (simplified)

Adapted from the operator README dedup contract. First matching diagnosis wins in `compute_diagnosis` (see `monitor.sh`).

```mermaid
flowchart TD
  start[Check cycle] --> ourNet{Our internet OK?}
  ourNet -->|no| ourDown[OUR_INTERNET_DOWN no email]
  ourNet -->|yes| tunnel{tunnel ping OK?}
  tunnel -->|yes| healthy[HEALTHY recovery if was DOWN]
  tunnel -->|no| udr7reach{Gateway SSH reachable?}
  udr7reach -->|no| udr7unreach[UDR7_UNREACHABLE Mac alerts]
  udr7reach -->|yes| disagree{Gateway says 0:UP?}
  disagree -->|yes| disagreement[DISAGREEMENT Mac alerts]
  disagree -->|no| dns{DDNS matches REMOTE_WAN_IP?}
  dns -->|no| drift[DDNS_DRIFT]
  dns -->|yes| wan{Remote WAN ping OK?}
  wan -->|no| remoteDown[REMOTE_INTERNET_DOWN]
  wan -->|yes| tunnelDown[TUNNEL_DOWN]
  tunnelDown --> threshold{failure_count >= FAILURE_THRESHOLD?}
  drift --> threshold
  remoteDown --> threshold
  disagreement --> threshold
  udr7unreach --> threshold
  threshold -->|yes new DOWN| dedup{Gateway already DOWN alert?}
  dedup -->|yes| bannerOnly[Banner only suppress email]
  dedup -->|no| emailBanner[Email and banner]
```

**Dedup email suppress:** When the gateway monitor is reachable and already in a DOWN alert state (`N:DOWN`), the Mac suppresses duplicate email but still shows a banner (except for `UDR7_UNREACHABLE` and `DISAGREEMENT` paths).

---

## Configuration save path (GUI)

```mermaid
sequenceDiagram
  participant U as User
  participant W as Configuration window
  participant C as ConfigEnvWriter
  participant O as osascript admin
  participant F as config.env

  U->>W: Save
  W->>C: render KEY=value lines
  W->>W: write temp file mode 0600
  W->>O: install to /opt/tunnel-monitor/config.env
  O->>F: root:wheel 0600
  W->>U: dismiss on success
```

---

## Setup window open flow (GUI)

Replaces the legacy “sheet inside menu bar” pattern.

```mermaid
sequenceDiagram
  participant U as User
  participant P as Menu popover
  participant Shell as AppShellController
  participant Opener as AppWindowOpener on menu label
  participant W as Configuration window

  U->>P: Setup
  P->>Shell: requestSetupWizard
  Shell->>Opener: openSetupWizardRequest true
  Opener->>W: openWindow id setup
  Opener->>Shell: clearSetupWizardRequest
```

`AppWindowOpener` is attached to the **menu bar label** (always loaded), not only inside the dashboard, so Setup works before any dashboard window exists.

---

## `state.json` fields (GUI-relevant)

| Field | Meaning |
|-------|---------|
| `alert_state` | `UP` or `DOWN` (alert latch) |
| `diagnosis` | Machine code: `HEALTHY`, `TUNNEL_DOWN`, `DDNS_DRIFT`, … |
| `failure_count` | Consecutive failing cycles while not healthy |
| `down_since` | ISO timestamp when down streak started (shown in UI when red) |
| `checks.tunnel` / `remote_wan` / `our_internet` | Per-check `ok`, `target`, `latency_ms` |
| `checks.dns` | `host`, `resolved`, `expected`, `match` |
| `udr7_dedup` or `router_dedup` | `reachable`, `state` (e.g. `0:UP`), `checked_at` |

The app decoder accepts either `udr7_dedup` or `router_dedup` for sanitized vs private deployments.

---

## Traffic light mapping (app)

| UI | Condition (simplified) |
|----|-------------------------|
| Green | `diagnosis` HEALTHY and `failure_count` 0 |
| Yellow | Unhealthy diagnosis or failures while `alert_state` still UP |
| Red | `alert_state` DOWN |

Poll interval is **not** the daemon interval. Settings only control how often the app re-reads `state.json` (5, 15, or 30 seconds).

---

## Changes from legacy monitor-only UX

| Before | Now |
|--------|-----|
| SwiftBar-only status | Native menu bar app + optional SwiftBar |
| First-run sheet in popover | Dedicated **Configuration** window |
| `StatusView` in popover only | `MenuBarPopoverView`; no sheets/alerts in popover |
| Dashboard via WindowGroup at launch | Dashboard suppressed until opened; Setup uses `id: setup` |

---

## Building from source

Release signing and notarization are documented only in the wiki: [Build and Release](https://github.com/roto31/UniFi-Tunnel-Monitor/wiki/Build-and-Release). Local builds: `bash build/build-app.sh` → `build/dist/Tunnel Monitor.app` (adhoc-signed when no Developer ID is set).
