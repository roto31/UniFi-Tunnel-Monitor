# OpenVPN site-to-site migration (when IPsec is blocked)

Use this checklist when an upstream ISP modem or CGNAT path blocks **UDP 500/4500** (IPsec) but general UDP still works.

**Official**

- Ubiquiti: [UniFi Gateway – OpenVPN Site-to-Site](https://help.ui.com/hc/en-us/articles/12646699585047-UniFi-Gateway-OpenVPN-Site-to-Site)

**Supplementary**

- [UniFi Network – Configuring Site-to-Site VPNs](https://www.appuntidallarete.com/unifi-network-configuring-site-to-site-vpns/) (double-NAT port notes)
- [LazyAdmin – UniFi Site-to-Site VPN](https://lazyadmin.nl/home-network/unifi-site-to-site-vpn/)

All names and IPs below are **examples**. Substitute your own tunnel names and addressing from [`PLACEHOLDERS.md`](../PLACEHOLDERS.md).

---

## 1. Generate the static key (512 hex chars)

Prefer generating on the **hub gateway** (matches Ubiquiti help center):

```bash
ssh root@REPLACE_WITH_HUB_GATEWAY_LAN_IP \
  'openvpn --genkey secret /tmp/s2s.key && wc -c /tmp/s2s.key && head -c 80 /tmp/s2s.key && echo ...'
```

Or paste Ubiquiti’s `openvpn --genkey` one-liner via SSH. **Never commit** the key file.

Ubiquiti’s article uses `[0-9a-z]` in `egrep`; `openvpn --genkey` output is hexadecimal — use `[0-9a-f]`.

---

## 2. Hub gateway — OpenVPN server side

UniFi Console → **hub site** → Settings → VPN → Site-to-Site VPN → **Create**

| Field | Example value |
|-------|---------------|
| Name | `Hub-to-Spoke-OpenVPN` |
| VPN type | OpenVPN |
| Pre-shared Key | Paste full 512-char hex from §1 |
| Local tunnel IP | `10.255.0.1` |
| Remote tunnel IP | `10.255.0.2` |
| Local Port | UDP `1194` |
| Remote Port | UDP `1194` |
| Remote hostname | `REPLACE_WITH_SPOKE_DDNS_HOSTNAME` (e.g. `spoke.example-ddns.test`) |
| Remote networks | Spoke LAN(s), e.g. `198.51.100.0/24` |

If the hub has **dual WAN**, bind OpenVPN to the **primary public WAN** (not a CGNAT backup). Example: hub public `203.0.113.10`, backup CGNAT `192.168.x.x` — tunnel must exit the public path.

---

## 3. Spoke gateway (often behind upstream NAT)

UniFi Site Manager → **spoke site** → Network → Settings → VPN → Site-to-Site VPN → **Create**

| Field | Example value |
|-------|---------------|
| Name | `Spoke-to-Hub-OpenVPN` |
| VPN type | OpenVPN |
| Pre-shared Key | Same paste as hub |
| Local tunnel IP | `10.255.0.2` |
| Remote tunnel IP | `10.255.0.1` |
| Local Port | UDP `1194` |
| Remote Port | UDP `1194` |
| Remote hostname | `REPLACE_WITH_HUB_DDNS_HOSTNAME` (e.g. `hub.example-ddns.test`) |
| Remote networks | Hub LAN(s), e.g. `192.0.2.0/24` |

**Upstream modem / double NAT**

- Prefer **DMZ → spoke UniFi WAN IP** (e.g. `198.51.100.50`) alone — avoid duplicate UDP 1194 forwards if UniFi listens on WAN.
- If the tunnel does not connect in ~60 s after both sides provision: try UDP `8443` on **both ends** simultaneously (some modems treat 1194 as VPN traffic).

UniFi FAQ: gateways behind upstream NAT usually need forwarding of the chosen OpenVPN port to the UniFi WAN IP.

---

## 4. Migrate policy routing (optional)

If you routed specific clients over the legacy IPsec tunnel, update **Policy Engine** rules to use the new OpenVPN tunnel interface (e.g. `Spoke-to-Hub-OpenVPN` instead of `Spoke-to-Hub-IPsec`).

---

## 5. Disable legacy IPsec tunnels

After OpenVPN shows **Connected** on both gateways:

- Delete or disable hub IPsec site-to-site tunnels.
- Delete or disable spoke IPsec site-to-site tunnels.

---

## 6. Verify from hub LAN Mac

```bash
ping -c 3 REPLACE_WITH_SPOKE_LAN_GATEWAY_IP
tunnel-check
sudo tunnel-check --reset
sudo tunnel-check --check-now
```

Tunnel Monitor continues to ping `REPLACE_WITH_REMOTE_LAN_GATEWAY_IP` — no repo code change required once routing over OpenVPN succeeds.

### SSH dedup host key rollover

```bash
sudo rm -f /opt/tunnel-monitor/.ssh/known_hosts
tunnel-check --ssh-test
sudo /opt/tunnel-monitor/ssh-udr7-state.sh
```

---

## Rollback

1. Restore IPsec tunnels on both sides using saved screenshots / backup `.unf`.
2. Point policy routes back to IPsec tunnel interfaces.
3. Remove OpenVPN S2S tunnels.

---

## Performance caveat

OpenVPN is CPU-bound on gateway-class hardware; IPsec WAN throughput on UDM-class gear is often higher. Tune streaming bitrates if multiple 4K streams buffer.

---

## Dual-WAN failover (hub with CGNAT backup)

When the hub’s **primary public WAN** fails, UniFi may fail over to a **CGNAT backup** (`192.168.x.x` or `100.64.x.x`). If **`REPLACE_WITH_HUB_DDNS_HOSTNAME`** is ever updated to that private address, **`Spoke-to-Hub-OpenVPN`** dials an unroutable target and the tunnel breaks — the same failure mode that broke IPsec.

Install **WAN Guard** on the **hub** gateway:

- **[WAN Guard + OpenVPN failover guide](wan-guard-openvpn-failover.md)**
- Package: [`unifi/wan-guard/`](../unifi/wan-guard/)

Summary: WAN Guard reads **primary public WAN only** (`WAN_GUARD_INTERFACE`), **blocks** DDNS updates when the IP is private/CGNAT, and **restores** DDNS when the public WAN returns. Disable UniFi DDNS on the CGNAT backup WAN so nothing else publishes a private address to your DDNS provider.
