# Spoke-side monitoring (optional)

**Optional** symmetric monitors at the **remote UniFi gateway** (and optionally a LAN Mac at the remote site). Complements hub-side monitoring without replacing it.

Uses the same packages as the hub:

- [`unifi/`](../unifi/README.md) on the **remote gateway**
- [`mac/`](../mac/README.md) on an optional **remote LAN Mac**

**WAN Guard stays on the hub only** — do not install it on the spoke.

---

## When to add spoke monitors

| Scenario | Spoke monitor helps |
|----------|---------------------|
| Remote site should receive its own alerts | UDM gateway monitor emails independently |
| Hub shows tunnel up but remote clients cannot reach hub LAN | Remote Mac LAN client monitor |
| Hub DDNS wrong (`REMOTE_DDNS` on spoke) | Spoke checks the hostname the remote tunnel dials |
| Operator at remote site during outages | Local email + optional Tailscale for SSH recovery |

Hub-only monitoring is sufficient for many deployments. Add spoke monitors when you need **independent vantage points** at the remote site.

---

## Inverted configuration

On the **hub**, monitors ping the **remote LAN gateway** and check the **remote site's public DDNS**.

On the **spoke**, invert every `REMOTE_*` value:

| Variable | Hub example | Spoke example |
|----------|-------------|---------------|
| `REMOTE_LAN_IP` | Remote LAN gateway (e.g. `198.51.100.1`) | **Local hub LAN gateway** (e.g. `192.0.2.1`) |
| `REMOTE_WAN_IP` | Remote public IP | **Hub public IP** |
| `REMOTE_DDNS` | Remote DDNS hostname | **Hub DDNS hostname** (what spoke VPN dials) |

Use distinct **`SUBJECT_PREFIX`** values (e.g. `[HUB-ROUTER]`, `[SPOKE-ROUTER]`, `[SPOKE-MAC]`) so alert sources are obvious.

---

## Install (generic)

Templates: [`spoke/`](../spoke/README.md) (`config.env.template` + deploy scripts).

### Remote gateway

```bash
export PUBLIC_UNIFI_SRC="/path/to/UniFi-Tunnel-Monitor/unifi"
export SPOKE_GATEWAY_LAN_IP="REPLACE_WITH_SPOKE_GATEWAY_LAN_IP"
bash spoke/udm/deploy-from-hub.sh
```

Or manually:

```bash
scp -r unifi/ root@REPLACE_WITH_SPOKE_GATEWAY_LAN_IP:/root/tunnel-monitor-src
ssh root@REPLACE_WITH_SPOKE_GATEWAY_LAN_IP
cd /root/tunnel-monitor-src
bash install.sh
nano /data/tunnel-monitor/config.env   # inverted REMOTE_* + SMTP
tunnel-check --test-email
tunnel-check
```

Reach the remote gateway over the VPN from the hub, or via out-of-band access (Tailscale, UniFi remote) when the tunnel is down.

### Optional remote LAN Mac

```bash
export PUBLIC_MAC_SRC="/path/to/UniFi-Tunnel-Monitor/mac"
sudo bash spoke/remote-mac/deploy-from-remote.sh
```

Or same as [mac/README.md](../mac/README.md), with:

- `REMOTE_LAN_IP` = hub LAN gateway (over tunnel)
- `REMOTE_WAN_IP` / `REMOTE_DDNS` = hub public IP / hub DDNS
- `ROUTER_HOST` = remote gateway LAN IP (for SSH dedup to spoke gateway state file)

---

## Dedup

- **Hub Mac** dedups against **hub gateway** state (`/data/tunnel-monitor/state`).
- **Spoke Mac** dedups against **spoke gateway** state on the same path.
- **Cross-site dedup** (hub suppressing when spoke already alerted) is not built in — expect independent emails during outages.

---

## Tailscale

Use Tailscale (or similar) for **operator SSH** when site-to-site VPN is down. Health checks should still use LAN/VPN paths to gateway and tunnel targets, not Tailscale IPs.

---

## See also

- [architecture.md](architecture.md) — hub dual-monitor design
- [implementation-guide.md](implementation-guide.md) — full install phases
- [`spoke/`](../spoke/README.md) — sanitized spoke config templates
