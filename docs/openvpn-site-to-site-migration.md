# OpenVPN site‑to‑site migration (XB7‑blocked IPsec)

Use this checklist when Comcast XB7 firmware blocks **UDP 500/4500** (IPsec) but general UDP flows still work.

**Official**

- Ubiquiti: [UniFi Gateway – OpenVPN Site‑to‑Site](https://help.ui.com/hc/en-us/articles/12646699585047-UniFi-Gateway-OpenVPN-Site-to-Site)

**Supplementary**

- [UniFi Network – Configuring Site‑to‑Site VPNs](https://www.appuntidallarete.com/unifi-network-configuring-site-to-site-vpns/) (covers double‑NAT port notes)
- [LazyAdmin – UniFi Site‑to‑Site VPN](https://lazyadmin.nl/home-network/unifi-site-to-site-vpn/)

## 1. Generate the static key (512 hex chars)

Prefer generating on Banana UDR7 (matches Ubiquiti help center):

From this repo clone on your Mac Studio:

```bash
bash scripts/gen-openvpn-s2s-key-remote.sh ~/Library/Application\ Support/tunnel-monitor-secrets/openvpn-s2s.key.hex
open -R ~/Library/Application\ Support/tunnel-monitor-secrets/openvpn-s2s.key.hex
```

Or paste Ubiquiti’s `openvpn --genkey` one‑liner via SSH (`help.ui.com` article). **Never commit** the key file.

Ubiquiti’s article uses `[0-9a-z]` in `egrep`; `openvpn --genkey` output is hexadecimal — use lowercase hex `[0-9a-f]` (the script handles this).

## 2. Banana (UDR7) — Site‑to‑Site OpenVPN server side

UniFi Console → Banana site → Settings → VPN → Site‑to‑Site VPN → **Create**

| Field | Value |
|-------|-------|
| Name | `Gam-and-Bee-OpenVPN` |
| VPN type | OpenVPN |
| Pre‑shared Key | Paste full 512‑char hex from §1 |
| Local tunnel IP | `10.255.0.1` |
| Remote tunnel IP | `10.255.0.2` |
| Local Port | UDP `1194` |
| Remote Port | UDP `1194` |
| Remote hostname | `gamandbeeu.onthewifi.com` |
| Remote networks | `192.168.0.0/24`, `192.168.21.0/24` |

Bind WAN to **WAN2 Midco public** if the UI exposes it (tunnel must exit `24.x` not `192.168.12.x`).

## 3. Gam and Bee (UDM behind XB7)

UniFi Site Manager → Gam and Bee → Network → Settings → VPN → Site‑to‑Site VPN → **Create**

| Field | Value |
|-------|-------|
| Name | `Home-OpenVPN` |
| VPN type | OpenVPN |
| Pre‑shared Key | Same paste as Banana |
| Local tunnel IP | `10.255.0.2` |
| Remote tunnel IP | `10.255.0.1` |
| Local Port | UDP `1194` |
| Remote Port | UDP `1194` |
| Remote hostname | `bananaudm.onthewifi.com` |
| Remote networks | `192.168.1.0/24` |

**XB7 / upstream**

- Prefer **DMZ → 10.0.0.42** alone (avoid duplicate UDP 1194 forwards if UniFi listens on WAN).
- If tunnel does not connect in ~60 s after both sides provision: try UDP `8443` on **both ends** simultaneously (some XB7 revisions treat 1194 as VPN).

UniFi FAQ: gateways behind upstream NAT usually need forwarding of the chosen OpenVPN port to the UniFi WAN IP.

## 4. Migrate AppleTV policy routing

Gam and Bee → Policy Engine → `AppleTV-Tunnel`:

- Interface / VPN Tunnel: select **`Home-OpenVPN`** (not `Home-Tunnel`).

## 5. Disable legacy IPsec tunnels

After OpenVPN shows **Connected** on both gateways:

- Delete or disable Banana `Gam and Bee Tunnel` (IPsec).
- Delete or disable Gam and Bee `Home-Tunnel` (IPsec).

## 6. Verify from Mac Studio

```bash
ping -c 3 192.168.0.1
tunnel-check           # readable state summary
sudo tunnel-check --reset
sudo tunnel-check --check-now
```

Tunnel Monitor continues to ping `192.168.0.1` — no repo code change required once routing over OpenVPN succeeds.

### SSH dedup host key rollover

```bash
sudo rm -f /opt/tunnel-monitor/.ssh/known_hosts
tunnel-check --ssh-test
sudo /opt/tunnel-monitor/ssh-udr7-state.sh
```

## Rollback

1. Restore IPsec tunnels on both sides using your saved screenshots / backup `.unf`.
2. Point AppleTV policy back to IPsec tunnel interface.
3. Remove OpenVPN S2S tunnels.

## Performance caveat

OpenVPN is CPU‑bound on gateway class hardware; IPSec WAN throughput on UDM‑class gear is higher. Tune AppleTV bitrate if multiple 4K streams buffer.

## Dual-WAN failover (Midco → T-Mobile backup)

When **WAN2 Midco** fails, UniFi may fail over to **WAN1 T-Mobile** (`192.168.12.x`). If **`bananaudm.onthewifi.com`** is ever updated to that CGNAT address, **`Home-OpenVPN`** on Gam-and-Bee dials an unroutable target and the tunnel breaks — the same failure mode that broke IPsec.

Install **WAN Guard** on the Banana UDR7 and follow the UniFi checklist:

- **[WAN Guard + OpenVPN failover guide](wan-guard-openvpn-failover.md)** — install, config values, runbook, UniFi DDNS/failover settings
- Package: [`Public/unifi/wan-guard/`](../unifi/wan-guard/)

Summary: WAN Guard reads **Midco only** (`WAN_GUARD_INTERFACE=eth4`), **blocks** No-IP updates when the IP is private/CGNAT, and **restores** DDNS when Midco returns. Disable UniFi DDNS on the T-Mobile WAN so nothing else publishes `192.168.12.x` to No-IP.
