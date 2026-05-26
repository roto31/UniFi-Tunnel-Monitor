# Spoke-side monitoring (sanitized templates)

Optional **remote-site** monitors that complement hub-side [`unifi/`](../unifi/README.md) and [`mac/`](../mac/README.md).

**WAN Guard stays on the hub only** — do not install [`wan-guard/`](../unifi/wan-guard/) on the spoke.

See [`docs/spoke-monitoring.md`](../docs/spoke-monitoring.md) for topology and dedup notes.

---

## Layout

```
spoke/
├── udm/                    # Remote UniFi gateway (spoke router)
│   ├── config.env.template
│   └── deploy-from-hub.sh
└── remote-mac/             # Optional LAN Mac at remote site
    ├── config.env.template
    └── deploy-from-remote.sh
```

Every value uses `REPLACE_WITH_*` placeholders. See [`PLACEHOLDERS.md`](../PLACEHOLDERS.md).

---

## Remote gateway

From a host that can SSH to the spoke over the VPN (or out-of-band):

```bash
export PUBLIC_UNIFI_SRC="/path/to/UniFi-Tunnel-Monitor/unifi"
export SPOKE_GATEWAY_LAN_IP="REPLACE_WITH_SPOKE_GATEWAY_LAN_IP"
bash spoke/udm/deploy-from-hub.sh
```

Then on the spoke gateway:

```bash
nano /data/tunnel-monitor/config.env   # SMTP + inverted REMOTE_* (hub targets)
tunnel-check --test-email
tunnel-check
```

---

## Optional remote LAN Mac

On the remote Mac:

```bash
export PUBLIC_MAC_SRC="/path/to/UniFi-Tunnel-Monitor/mac"
sudo bash spoke/remote-mac/deploy-from-remote.sh
sudo nano /opt/tunnel-monitor/config.env
tunnel-check --test-email
tunnel-check --ssh-test
```

---

## Inverted `REMOTE_*` values (spoke)

| Variable | Spoke meaning |
|----------|----------------|
| `REMOTE_LAN_IP` | Hub LAN gateway (reachable over tunnel) |
| `REMOTE_WAN_IP` | Hub public IP |
| `REMOTE_DDNS` | Hub DDNS hostname (what spoke VPN dials) |

Use a distinct `SUBJECT_PREFIX` (e.g. `[SPOKE-ROUTER]`, `[SPOKE-MAC]`).
