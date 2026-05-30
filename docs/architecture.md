# Architecture

This document explains how the monitoring stack fits together:

- **UniFi gateway monitor** (systemd on local hub)
- **Mac LAN client monitor** (launchd + optional SwiftBar)
- **WAN Guard** (optional, dual-WAN DDNS on local hub)
- **Site-to-site VPN** (IPsec or OpenVPN — transport is independent of monitors)

Diagrams use Mermaid. See also [network-overview.md](network-overview.md) and
[getting-started.md](getting-started.md).

---

## 1. Component diagram

```mermaid
flowchart TB
    subgraph LOCAL_SITE["Local site (your home / office)"]
        direction TB
        subgraph MAC["Mac on the LAN"]
            MONITOR["monitor.sh<br/>(LaunchDaemon, every 5 min)"]
            STATEJSON[("state.json<br/>atomic JSON state")]
            LOGFILE[("monitor.log<br/>rotates at 1 MB")]
            SWIFTBAR["SwiftBar plugin<br/>tunnel-monitor.30s.sh<br/>(every 30 s, read-only)"]
            TC["tunnel-check<br/>(operator CLI)"]
            NOTIFY["notify.sh<br/>(launchctl asuser + osascript)"]
            SEND_M["send-email.sh<br/>(curl SMTP)"]
            SSH_R["ssh-router-state.sh<br/>(ssh + jq)"]
        end

        subgraph GW["UniFi gateway (local hub)"]
            UMON["monitor.sh<br/>(systemd timer, every 5 min)"]
            USTATE[("/data/tunnel-monitor/state<br/>'N:UP' or 'N:DOWN'")]
            USEND["send-email.sh<br/>(curl SMTP)"]
            UTC["tunnel-check<br/>(operator CLI)"]
            WG["wan-guard.sh<br/>(optional, every 5 min)"]
            WGSTATE[("wan-guard.state")]
        end

        NC["macOS Notification Center"]
    end

    subgraph REMOTE_SITE["Remote site"]
        REMOTE_GW["Remote LAN gateway<br/>(REMOTE_LAN_IP)"]
    end

    SMTP["SMTP provider"]
    PUBDNS["1.1.1.1 (DNS / sanity)"]

    MONITOR -- "ping REMOTE_LAN_IP<br/>(over tunnel)" --> REMOTE_GW
    UMON    -- "ping REMOTE_LAN_IP<br/>(over tunnel)" --> REMOTE_GW

    MONITOR -- "read" --> SSH_R
    SSH_R   -- "ssh + cat" --> USTATE
    MONITOR -- "writes" --> STATEJSON
    MONITOR -- "writes" --> LOGFILE
    MONITOR -- "invokes" --> NOTIFY
    MONITOR -- "invokes" --> SEND_M
    NOTIFY  -- "launchctl asuser" --> NC
    SEND_M  -- "curl smtp://" --> SMTP

    UMON    -- "writes" --> USTATE
    UMON    -- "invokes" --> USEND
    USEND   -- "curl smtp://" --> SMTP
    WG      -- "writes" --> WGSTATE
    WG      -- "No-IP sync<br/>(primary WAN only)" --> PUBDNS

    SWIFTBAR -- "reads" --> STATEJSON
    TC       -- "reads" --> STATEJSON
    UTC      -- "reads" --> USTATE

    MONITOR  -- "dig" --> PUBDNS
    UMON     -- "dig" --> PUBDNS
```

Key takeaways:

- The **gateway side** is self-contained — it monitors, decides, and emails
  on its own. The state file is its only "API" to anyone else.
- The **Mac side** does its own pings *and* reads the gateway's state file
  over SSH to decide whether to suppress its email (dedup).
- `state.json` on the Mac is the single source of truth for **Tunnel Monitor.app**,
  the SwiftBar plugin, and `tunnel-check` — none of them run their own checks.
- **GUI architecture** (menu bar app, Configuration window, alert flow):
  [tunnel-monitor/02-architecture.md](tunnel-monitor/02-architecture.md).
- Both sides use `curl`'s built-in SMTP client to authenticate and submit
  via STARTTLS on port 587.
- **WAN Guard** (optional) shares SMTP config with the gateway monitor and
  only protects **hub DDNS** when dual WAN + remote dial-in VPN — see
  [wan-guard-openvpn-failover.md](wan-guard-openvpn-failover.md).

---

## 1b. VPN transport vs monitoring

Monitors ping **`REMOTE_LAN_IP`** over whatever VPN UniFi routes — IPsec or
OpenVPN. They do **not** restart VPN daemons.

| Layer | Checked by | Not checked by |
|-------|------------|----------------|
| OpenVPN / IPsec SA | Gateway `ipsec` logs (IPsec) or UniFi UI | Mac (unless tunnel ping fails) |
| End-to-end reachability | Both monitors (ping) | WAN Guard |
| Hub DDNS correctness | WAN Guard | tunnel-monitor (uses **remote** DDNS) |

---

## 2. Data flow (Mac side, one full check cycle)

```mermaid
sequenceDiagram
    participant LAUNCHD as launchd
    participant MAC as monitor.sh
    participant SSH as ssh-router-state.sh
    participant GW as UniFi gateway<br/>(state file)
    participant SMTP as SMTP provider
    participant NC as Notification Center
    participant FS as state.json

    LAUNCHD->>MAC: invoke (StartInterval=300)
    MAC->>MAC: load config.env
    MAC->>MAC: ping REMOTE_LAN_IP / WAN / 1.1.1.1
    MAC->>MAC: dig REMOTE_DDNS @1.1.1.1
    MAC->>SSH: read router state
    SSH->>GW: ssh -i KEY USER@HOST 'cat /data/tunnel-monitor/state'
    GW-->>SSH: "N:UP" or "N:DOWN"
    SSH-->>MAC: same (or non-zero on failure)
    MAC->>MAC: diagnose() — apply decision tree
    alt threshold crossed && router said DOWN
        MAC->>NC: banner (DOWN)
        MAC--xSMTP: email SUPPRESSED (dedup)
    else threshold crossed && router not DOWN
        MAC->>NC: banner (DOWN)
        MAC->>SMTP: send DOWN email
    else recovery (DOWN -> UP)
        MAC->>NC: banner (RECOVERED)
        MAC->>SMTP: send recovery email
    else still counting
        Note over MAC: log only, no alert
    end
    MAC->>FS: atomic write state.json
    MAC-->>LAUNCHD: exit 0 (always)
```

---

## 3. Dedup decision tree

This is the order applied by `diagnose()` in `mac/payload/opt/tunnel-monitor/monitor.sh`.
First match wins.

```mermaid
flowchart TD
    START([health checks complete]) --> Q1{our internet up?<br/>ping 1.1.1.1}
    Q1 -- no --> OID["OUR_INTERNET_DOWN<br/>hold state, no alert"]:::skip
    Q1 -- yes --> Q2{tunnel ping ok?}
    Q2 -- yes --> H["HEALTHY<br/>reset count<br/>send recovery if was DOWN"]:::ok
    Q2 -- no --> Q3{router reachable<br/>via ssh?}
    Q3 -- no --> RU["ROUTER_UNREACHABLE<br/>alert (no dedup)"]:::alert
    Q3 -- yes --> Q4{router state<br/>== 0:UP?}
    Q4 -- yes --> DA["DISAGREEMENT<br/>(Mac sees down,<br/>router sees up)<br/>alert"]:::alert
    Q4 -- no --> Q5{DDNS resolves<br/>== REMOTE_WAN_IP?}
    Q5 -- no --> DD["DDNS_DRIFT<br/>alert"]:::alert
    Q5 -- yes --> Q6{ping REMOTE_WAN_IP<br/>over internet ok?}
    Q6 -- no --> RID["REMOTE_INTERNET_DOWN<br/>alert"]:::alert
    Q6 -- yes --> TD["TUNNEL_DOWN<br/>alert"]:::alert

    RU --> DEDUP
    DA --> DEDUP
    DD --> DEDUP
    RID --> DEDUP
    TD --> DEDUP

    DEDUP{threshold crossed<br/>AND router state<br/>is *:DOWN?}
    DEDUP -- yes --> SUPP["banner only<br/>(suppress email)"]:::suppress
    DEDUP -- no --> FULL["banner + email"]:::alert

    classDef ok       fill:#e6f4ea,stroke:#137333,color:#0a3d20;
    classDef skip     fill:#eceff1,stroke:#546e7a,color:#1c2a33;
    classDef alert    fill:#fce8e6,stroke:#c5221f,color:#5b0f0a;
    classDef suppress fill:#fff8e1,stroke:#a8741f,color:#3e2a04;
```

The router-side decision tree is simpler: it doesn't talk to anyone, it just
classifies the failure (REMOTE INTERNET DOWN / DDNS DRIFT / TUNNEL DOWN) and
emails after `FAILURE_THRESHOLD` consecutive failures.

---

## 4. State machine (shared between both sides)

```mermaid
stateDiagram-v2
    [*] --> UP_0
    UP_0: UP / count=0
    UP_N: UP / count=N (1..T-1)
    DOWN_N: DOWN / count=N (>=T)

    UP_0   --> UP_0 : ping ok
    UP_0   --> UP_N : ping fail
    UP_N   --> UP_0 : ping ok
    UP_N   --> UP_N : ping fail, count < T
    UP_N   --> DOWN_N : ping fail, count >= T<br/>** alert sent **
    DOWN_N --> DOWN_N : ping fail<br/>(no re-alert)
    DOWN_N --> UP_0 : ping ok<br/>** recovery sent **

    note right of UP_N
        T = FAILURE_THRESHOLD
        (default 3)
    end note
```

The state file format encodes both fields in a single string:

| Format       | Meaning                                                              |
|--------------|----------------------------------------------------------------------|
| `0:UP`       | Healthy, no failures recorded                                        |
| `2:UP`       | 2 consecutive failures, threshold not crossed, no alert yet          |
| `3:DOWN`     | Threshold crossed, alert sent, currently in DOWN                     |
| `7:DOWN`     | Still down after several more failed checks; no re-alert             |

On the Mac side, this state lives inside `state.json` as the `alert_state`
and `failure_count` fields; the SSH-dedup script reads the router's
plaintext file and translates it back into the same fields for its own
decision making.

---

## 5. Network topology (illustrative — uses RFC 5737 docs IPs)

```mermaid
flowchart LR
    subgraph LOCAL["LOCAL SITE"]
        MAC_DEV["Mac<br/>(LAN client)<br/>192.0.2.10"]
        LAN_LOCAL["LAN<br/>192.0.2.0/24"]
        ROUTER_LOCAL["UniFi gateway<br/>LAN: 192.0.2.1"]

        MAC_DEV --- LAN_LOCAL
        LAN_LOCAL --- ROUTER_LOCAL
    end

    subgraph REMOTE["REMOTE SITE"]
        REMOTE_GW["Remote LAN gateway<br/>LAN: 198.51.100.1"]
        LAN_REMOTE["LAN<br/>198.51.100.0/24"]
        REMOTE_DEV["Client device<br/>198.51.100.50"]

        REMOTE_GW --- LAN_REMOTE
        LAN_REMOTE --- REMOTE_DEV
    end

    ROUTER_LOCAL <-. "Site-to-site VPN<br/>(IPsec or OpenVPN)" .-> REMOTE_GW
    ROUTER_LOCAL -. "WAN<br/>local public IP" .-> INTERNET((Internet))
    REMOTE_GW    -. "WAN<br/>REMOTE_WAN_IP" .-> INTERNET

    DDNS["DDNS provider<br/>REMOTE_DDNS A record<br/>-> REMOTE_WAN_IP"]
    INTERNET --- DDNS
```

In a real deployment, replace the doc-net IPs with your actual values from
the config templates:

| Diagram label                  | Config var                 |
|--------------------------------|----------------------------|
| `LAN: 192.0.2.1`               | `ROUTER_HOST` (Mac side)   |
| `LAN: 198.51.100.1`            | `REMOTE_LAN_IP`            |
| `WAN: REMOTE_WAN_IP`           | `REMOTE_WAN_IP`            |
| `DDNS provider`                | `REMOTE_DDNS`              |

---

## 6. Why two monitors?

Either side alone has a blind spot:

- **Router-only monitor.** The router sees its own IPsec SA state. If the
  SA is `ESTABLISHED` but the routing or firewall rules for clients are
  broken, the monitor still says "UP" because its own pings work (the
  router's IP is on every relevant interface). A real LAN client wouldn't
  be able to reach the remote site, but the alert never fires.
- **Mac-only monitor.** The Mac sees what a real client experiences but
  has no insight into IPsec internals, can't read strongSwan logs, and
  can't restart the tunnel. When pings fail, the diagnosis is limited.

The two-monitor design covers both blind spots and also catches the case
where the router itself is unreachable (the Mac side flags
`ROUTER_UNREACHABLE` and takes over alerting).

### Optional spoke-side monitors

The same hub pattern can be mirrored at the **remote site**: gateway monitor
on the remote UniFi device plus optional LAN Mac, with **inverted**
`REMOTE_LAN_IP`, `REMOTE_WAN_IP`, and `REMOTE_DDNS`. WAN Guard remains
hub-only.

Generic guide: [spoke-monitoring.md](spoke-monitoring.md).

---

## 7. SSH-based dedup mechanic

```mermaid
sequenceDiagram
    participant MAC_M as Mac monitor.sh
    participant MAC_SSH as ssh-router-state.sh
    participant SSH as ssh client BatchMode
    participant GW as UniFi gateway
    participant GW_STATE as router state file

    MAC_M->>MAC_SSH: invoke each cycle
    MAC_SSH->>MAC_SSH: source config env
    MAC_SSH->>SSH: ssh cat state path on router
    SSH->>GW: TCP 22
    GW->>GW_STATE: read file
    GW_STATE-->>GW: N colon UP or DOWN
    GW-->>SSH: stdout
    SSH-->>MAC_SSH: stdout
    MAC_SSH->>MAC_SSH: validate N colon UP or DOWN pattern
    alt Valid state line
        MAC_SSH-->>MAC_M: print line and exit 0
    else SSH failed or malformed line
        MAC_SSH-->>MAC_M: exit non-zero
        Note over MAC_M: treat as router unreachable ROUTER_UNREACHABLE
    end
```

The SSH session uses a dedicated ed25519 key at `/opt/tunnel-monitor/.ssh/id_ed25519`
created by the Mac installer. The corresponding public key is appended to
the router's `~/.ssh/authorized_keys` during install (you'll be prompted for
the router root password once).

Both sides survive the other being unreachable:

- Router unreachable → Mac alerts on its own with `ROUTER_UNREACHABLE`.
- Mac unreachable / not running → router alerts as it always did.
- Both running, both see DOWN → router alerts first (it's checked over the
  tunnel directly); Mac suppresses its email but still posts a banner so
  the operator sees the alert without opening their inbox.

---

## 8. File-level data dependencies

```mermaid
flowchart LR
    CFG_M["mac/config.env"]
    CFG_U["unifi/config.env"]
    STATE_M["mac/state.json"]
    STATE_U["unifi/state"]
    LOG_M["mac/monitor.log"]
    LAUNCH_LOG_OUT["mac/launchd.stdout.log"]
    LAUNCH_LOG_ERR["mac/launchd.stderr.log"]

    MACMON["mac/monitor.sh"]
    MACSEND["mac/send-email.sh"]
    MACSSH["mac/ssh-router-state.sh"]
    MACNOTIFY["mac/notify.sh"]
    MACTC["mac/tunnel-check"]
    SWBAR["mac/SwiftBar plugin"]

    UMON["unifi/monitor.sh"]
    USEND["unifi/send-email.sh"]
    UTC["unifi/tunnel-check"]

    CFG_M --> MACMON
    CFG_M --> MACSEND
    CFG_M --> MACSSH
    CFG_M --> MACNOTIFY
    CFG_U --> UMON
    CFG_U --> USEND

    MACMON --> STATE_M
    MACMON --> LOG_M
    MACMON --> LAUNCH_LOG_OUT
    MACMON --> LAUNCH_LOG_ERR
    UMON   --> STATE_U

    STATE_M --> SWBAR
    STATE_M --> MACTC
    STATE_U --> UTC
    STATE_U --> MACSSH

    MACMON --> MACSEND
    MACMON --> MACNOTIFY
    MACMON --> MACSSH
    UMON   --> USEND
```

If you ever wonder "what reads this file?" or "what writes this file?", this
diagram is the answer.
