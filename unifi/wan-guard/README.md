# WAN Guard (UDR7)

Protects **`hub.example.net`** from being updated with a **T-Mobile CGNAT** (`192.168.100.x`) address when primary ISP WAN2 fails — which would break **OpenVPN site-to-site** (`Spoke-to-Hub-OpenVPN` / `Spoke-OpenVPN`) the same way it broke IPsec.

**Full operator guide:** [`Public/docs/wan-guard-openvpn-failover.md`](../../docs/wan-guard-openvpn-failover.md)

## Quick install (Hub UDR7)

```bash
scp -r Public/unifi/wan-guard/ root@192.168.1.1:/root/wan-guard-src
ssh root@192.168.1.1 'cd /root/wan-guard-src && bash install.sh'
# Edit /data/tunnel-monitor/config.env → set WAN_GUARD_NOIP_PASS
wan-guard test-email && wan-guard check && wan-guard status
```

## Files

| Path on UDR7 | Purpose |
|--------------|---------|
| `/data/wan-guard/wan-guard.sh` | Main checker |
| `/data/wan-guard/wan-guard.state` | Last IP / status |
| `/data/wan-guard/wan-guard.log` | Rolling log |
| `/data/tunnel-monitor/config.env` | Shared SMTP + `WAN_GUARD_*` keys |

Timer: **`wan-guard.timer`** — every 5 minutes (offset from tunnel-monitor).

## Tests

```bash
bash test-wan-guard.sh
```
