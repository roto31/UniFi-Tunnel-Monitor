# Network overview (generic topology)

Illustrative layout for a **local hub** + **remote spoke** deployment. Replace placeholder IPs with your values ([`PLACEHOLDERS.md`](../PLACEHOLDERS.md)).

---

## Site diagram

```mermaid
flowchart TB
    subgraph LOCAL["Local site"]
        MAC["LAN client<br/>192.0.2.10<br/>(Mac monitor)"]
        LAN_L["LAN 192.0.2.0/24"]
        GW_L["UniFi gateway<br/>LAN 192.0.2.1<br/>(local hub)"]
        WAN_P["Primary WAN<br/>public IP"]
        WAN_B["Backup WAN<br/>optional CGNAT"]
        MAC --- LAN_L --- GW_L
        GW_L --- WAN_P
        GW_L --- WAN_B
    end

    subgraph REMOTE["Remote site"]
        MODEM["ISP modem<br/>optional double-NAT"]
        GW_R["UniFi gateway<br/>LAN 198.51.100.1<br/>(remote spoke)"]
        LAN_R["LAN 198.51.100.0/24"]
        MODEM --- GW_R --- LAN_R
    end

    WAN_P <-. "VPN tunnel<br/>IPsec or OpenVPN" .-> MODEM
    DDNS_H["DDNS hub.example.com"] -.-> WAN_P
    DDNS_R["DDNS remote.example.com"] -.-> MODEM
```

---

## Address mapping

| Role | Example placeholder | Config variable |
|------|---------------------|-----------------|
| Local gateway LAN | `192.0.2.1` | `ROUTER_HOST` (Mac SSH) |
| Mac on local LAN | `192.0.2.10` | (not in config) |
| Remote LAN gateway | `198.51.100.1` | `REMOTE_LAN_IP` |
| Remote public IP | `198.51.100.50` | `REMOTE_WAN_IP` |
| Remote DDNS | `remote.example.com` | `REMOTE_DDNS` |
| Local hub DDNS (dual WAN) | `hub.example.com` | `WAN_GUARD_HOSTNAME` |

RFC 5737 blocks (`192.0.2.0/24`, `198.51.100.0/24`) are **documentation only** — not routable on the public internet.

---

## VPN options

| Transport | When to use | Ports |
|-----------|-------------|-------|
| **IPsec** | Both sites have public or straightforward NAT | UDP 500, 4500 |
| **OpenVPN** | Upstream modem blocks IPsec | UDP 1194 (or 8443) |

OpenVPN tunnel IPs (example): `10.255.0.1` (hub) ↔ `10.255.0.2` (spoke) on a `/30` or as UniFi assigns.

---

## Dual WAN (local hub only)

```mermaid
flowchart LR
    subgraph HUB["Local hub"]
        P["Primary WAN<br/>public"]
        B["Backup WAN<br/>CGNAT 192.168.x"]
    end

    NOIP["DDNS provider"]
    WG["WAN Guard<br/>reads primary interface only"]
    VPN["Remote spoke<br/>dials DDNS"]

    P --> WG
    WG --> NOIP
    VPN --> NOIP
    B -. "must NOT update DDNS" .-> NOIP
```

Without WAN Guard, failover can publish a **private** address → remote VPN breaks. See [wan-guard-openvpn-failover.md](wan-guard-openvpn-failover.md).

---

## Monitoring traffic flows

| From | To | Purpose |
|------|-----|---------|
| Mac monitor | `REMOTE_LAN_IP` | Tunnel health (client view) |
| Mac monitor | `REMOTE_WAN_IP` | Remote ISP up? |
| Mac monitor | `ROUTER_HOST` SSH | Dedup state read |
| Gateway monitor | `REMOTE_LAN_IP` | Tunnel health (router view) |
| Gateway monitor | `REMOTE_WAN_IP` | Remote ISP up? |
| WAN Guard | Primary WAN interface | DDNS sync |
| Remote spoke | Hub DDNS:port | OpenVPN initiate |

---

## UniFi object naming (suggested)

Use **consistent names** across sites:

| Site | Suggested tunnel name | Points to |
|------|----------------------|-----------|
| Local hub | `Remote-Site-OpenVPN` | `remote.example.com` |
| Remote spoke | `Spoke-to-Hub-OpenVPN` | `hub.example.com` |

Policy routing objects should reference the **OpenVPN** tunnel name after migration off IPsec.

---

## External references

- [RFC 5737 — TEST-NET addresses](https://www.rfc-editor.org/rfc/rfc5737)
- [Ubiquiti VPN documentation](https://help.ui.com/hc/en-us/articles/115001218267-UniFi-Gateway-Route-Based-VPN-IPsec)
