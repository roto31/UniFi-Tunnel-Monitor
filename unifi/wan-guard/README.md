# WAN Guard (dual-WAN hub)

Protects **`REPLACE_WITH_HUB_DDNS_HOSTNAME`** from being updated with a **CGNAT backup WAN** address when the **primary public WAN** fails — which breaks **OpenVPN site-to-site** the same way it broke IPsec.

**Full operator guide:** [`docs/wan-guard-openvpn-failover.md`](../../docs/wan-guard-openvpn-failover.md)

## Quick install (hub gateway)

```bash
scp -r unifi/wan-guard/ root@REPLACE_WITH_HUB_GATEWAY_LAN_IP:/root/wan-guard-src
ssh root@REPLACE_WITH_HUB_GATEWAY_LAN_IP 'cd /root/wan-guard-src && bash install.sh'
# Edit /data/tunnel-monitor/config.env → WAN_GUARD_* + No-IP credentials
wan-guard test-email && wan-guard check && wan-guard status
```

## Files

| Path on gateway | Purpose |
|-----------------|---------|
| `/data/wan-guard/wan-guard.sh` | Main checker |
| `/data/wan-guard/wan-guard.state` | Last IP / status |
| `/data/wan-guard/wan-guard.log` | Rolling log |
| `/data/tunnel-monitor/config.env` | Shared SMTP + `WAN_GUARD_*` keys |

Timer: **`wan-guard.timer`** — every 5 minutes (offset from tunnel-monitor).

## Tests

```bash
bash test-wan-guard.sh
```
