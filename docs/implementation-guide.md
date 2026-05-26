# Implementation guide

Step-by-step replication for UniFi site-to-site VPN monitoring. Uses **placeholder** values — map them in [`PLACEHOLDERS.md`](../PLACEHOLDERS.md).

---

## Phase 0 — Gather information

| Item | Your value | Config key |
|------|------------|------------|
| Local gateway LAN IP | e.g. `192.0.2.1` | `ROUTER_HOST` (Mac) |
| Remote LAN gateway | e.g. `198.51.100.1` | `REMOTE_LAN_IP` |
| Remote public IP | e.g. `198.51.100.50` | `REMOTE_WAN_IP` |
| Remote DDNS hostname | e.g. `remote.example.com` | `REMOTE_DDNS` |
| Alert email | your address | `ALERT_TO` |
| SMTP credentials | app password | `SMTP_*` |

Draw a one-line diagram: **Local hub LAN** ↔ **VPN** ↔ **Remote spoke LAN**.

---

## Phase 1 — Site-to-site VPN

### Option A — IPsec (default UniFi)

1. UniFi **Local hub** → Settings → VPN → Site-to-Site → create tunnel to remote.
2. UniFi **Remote spoke** → mirror config.
3. Verify: from local gateway SSH, `ping -c 3 REMOTE_LAN_IP`.

**If IKE never establishes** and remote is behind an ISP modem, test whether UDP **500/4500** reach the UniFi WAN. If blocked → Option B.

References: [Ubiquiti IPsec VPN](https://help.ui.com/hc/en-us/articles/115001218267-UniFi-Gateway-Route-Based-VPN-IPsec).

### Option B — OpenVPN (modem blocks IPsec)

Follow [openvpn-site-to-site-migration.md](openvpn-site-to-site-migration.md):

1. Generate **512-character hex** static key (Ubiquiti `openvpn --genkey` pattern).
2. Create matching tunnels on **both** gateways (tunnel IPs e.g. `10.255.0.1` / `10.255.0.2`).
3. Remote behind NAT: DMZ or port-forward **UDP 1194** (or **8443** on both ends).
4. Disable legacy IPsec after both show **Connected**.

Official: [Ubiquiti OpenVPN Site-to-Site](https://help.ui.com/hc/en-us/articles/12646699585047-UniFi-Gateway-OpenVPN-Site-to-Site).

---

## Phase 2 — Gateway monitor (local hub)

```bash
scp -r unifi/ root@YOUR_ROUTER_LAN_IP:/root/tunnel-monitor-src
ssh root@YOUR_ROUTER_LAN_IP
cd /root/tunnel-monitor-src
bash install.sh
nano /data/tunnel-monitor/config.env   # fill placeholders
tunnel-check --test-email
systemctl start tunnel-monitor.service
tunnel-check
```

Expected: state `0:UP`, timer active. See [unifi/README.md](../unifi/README.md).

**Survives firmware?** Files in `/data/tunnel-monitor/` yes; re-run `install.sh` after updates for systemd units.

---

## Phase 3 — Mac LAN monitor (local site)

```bash
cd mac/
sudo bash install.sh
sudo vi /opt/tunnel-monitor/config.env
# Authorize SSH key on gateway when prompted
tunnel-check --test-email
tunnel-check --test-notify
sudo bash verify.sh
```

Optional: install SwiftBar (`brew install --cask swiftbar`).

See [mac/README.md](../mac/README.md).

**Dedup test:** `tunnel-check --ssh-test` must return gateway state line `N:UP` or `N:DOWN`.

---

## Phase 4 — WAN Guard (optional, dual WAN)

**Only if:**

- Local hub has **primary public WAN** + **CGNAT backup WAN**, and
- Remote VPN connects to your **DDNS name**.

```bash
scp -r unifi/wan-guard/ root@YOUR_ROUTER_LAN_IP:/root/wan-guard-src
ssh root@YOUR_ROUTER_LAN_IP
cd /root/wan-guard-src
bash install.sh
nano /data/tunnel-monitor/config.env   # WAN_GUARD_* keys
```

UniFi checklist ([full doc](wan-guard-openvpn-failover.md)):

- [ ] Disable Dynamic DNS on **CGNAT WAN**
- [ ] Disable Dynamic DNS on **public WAN** (let WAN Guard own updates)
- [ ] Set `WAN_GUARD_INTERFACE` to **public WAN** interface (`ip -4 addr`)
- [ ] Remote tunnel uses **hostname**, not static IP

Verify:

```bash
wan-guard test-email
wan-guard check
wan-guard status
```

---

## Phase 5 — Policy routing (optional)

If you force specific clients over the VPN (e.g. streaming devices):

1. Remote spoke → Policy Engine → create policy.
2. Set **Interface / VPN** to your **OpenVPN tunnel name** (not legacy IPsec).

---

## Phase 6 — Acceptance tests

| Test | Command / action | Pass |
|------|------------------|------|
| Tunnel ping | `ping REMOTE_LAN_IP` from Mac | Replies |
| Gateway status | `tunnel-check` on gateway | `0:UP` |
| Mac status | `tunnel-check` on Mac | `HEALTHY` |
| SSH dedup | `tunnel-check --ssh-test` on Mac | Success |
| Email | `--test-email` both sides | Received |
| WAN Guard | `wan-guard status` | `in_sync` (if installed) |

Simulate failure (advanced): see [troubleshooting.md](troubleshooting.md) and [mac/README.md](../mac/README.md) testing section.

---

## Phase 6b — Spoke monitors (optional)

If the **remote site** should alert independently or you want a LAN client
vantage there, install inverted monitors on the remote gateway (and
optionally a remote Mac). **Do not** install WAN Guard on the spoke.

See [spoke-monitoring.md](spoke-monitoring.md) for generic steps and config
inversion.

---

## Phase 7 — Ongoing maintenance

| Event | Action |
|-------|--------|
| UniFi firmware update | Re-run `install.sh` for gateway monitor (+ WAN Guard) |
| Remote ISP IP change | Update DDNS; monitors detect drift |
| Local dual-WAN interface rename | Update `WAN_GUARD_INTERFACE`; re-run `wan-guard check` |
| macOS major upgrade | `sudo bash verify.sh` on Mac |

---

## Architecture reference

After install, read [architecture.md](architecture.md) for dedup logic and state machine — essential when interpreting alert subjects.
