# wg-manage

WireGuard peer management CLI for multi-hub deployments. Automates peer creation, deletion, suspension, IP allocation, client config generation, QR codes, git versioning, and routing — all with zero downtime.

## Quick Start

```bash
# List all peers
wg-manage list

# Add a new peer (auto-IP in MN subnet)
wg-manage add dev01

# Add a peer with custom IP
wg-manage add dev02 --ip 10.232.0.77

# Add a peer in SGP subnet
wg-manage add sgp-peer --hub sgp

# View peer details + client config
wg-manage show dev01

# Show QR code for mobile setup
wg-manage qr dev01

# Suspend / restore / remove
wg-manage suspend dev01
wg-manage unsuspend dev01
wg-manage remove dev01 --force

# Rename a peer
wg-manage rename pbs4-95 dc04-pbs4 --force

# Change peer IP (hub auto-detected)
wg-manage ip dc04-pbs4 10.232.7.100 --force

# Restore from backup
wg-manage restore --latest --force                    # full restore
wg-manage restore --latest --peer dev01 --force       # single peer

# Search peers
wg-manage list gpu                    # name search
wg-manage list active --hub mn        # filter by hub
```

## Commands

| Command | Description |
|---|---|
| `add <name> [opts]` | Create peer with auto keygen, IP assignment, client config |
| `remove <name>` | Delete peer and all configs |
| `suspend <name>` | Temporarily disable peer (preserves IP) |
| `unsuspend <name>` | Restore suspended peer |
| `rename <old> <new>` | Rename peer (preserves keys, session uninterrupted) |
| `ip <name> <ip>` | Change peer IP address (hub auto-detected) |
| `list [filter]` | List peers with live status |
| `show <name>` | Detailed peer info + client config |
| `qr <name>` | Show QR code for mobile import |
| `sync` | Rebuild WireGuard interface from configs |
| `restore <file>\|--latest` | Restore from backup (full or `--peer <name>` for single peer) |
| `info` | Server overview |
| `backup` | Manual snapshot |

## Add Options

| Flag | Description |
|---|---|
| `--hub mn\|sgp\|us\|eu` | Hub for IP allocation (default: mn) |
| `--ip 10.232.0.77` | Specific IP address |
| `--allowed-ips 10.232.0.0/16` | Client AllowedIPs (default: all hub subnets) |
| `--dns 1.1.1.1` | DNS in client config (commented by default) |
| `--desc "text"` | Description / label |
| `--psk` | Generate PresharedKey |

## Architecture

All peers connect to the **MN hub** server. Traffic to other hubs (SGP, future US/EU) routes through hub-to-hub WireGuard tunnels. See [ARCHITECTURE.md](ARCHITECTURE.md) for topology and routing details.

```
Client → vpn-server.example.com:51820 → MN Server → tunnel → SGP
```

## Configuration

Edit `/etc/wireguard/wg-manage.conf`:

```bash
WG_DEFAULT_HUB="mn"
WG_DEFAULT_DNS="1.1.1.1,8.8.8.8"
WG_BACKUP_KEEP=10

# Hub subnets
WG_HUB_MN_SUBNET="10.232.0.0/16"
WG_HUB_SGP_SUBNET="10.233.0.0/16"

# Client AllowedIPs (space-separated subnets)
WG_CLIENT_ALLOWED_IPS="10.232.0.0/16 10.233.0.0/16"

# Hub endpoints
WG_HUB_MN_ENDPOINT="vpn-server.example.com:51820"
WG_HUB_SGP_ENDPOINT="sgp-server.example.com:51820"
```

## Files

| Path | Purpose |
|---|---|
| `/etc/wireguard/peers/` | Active peer configs |
| `/etc/wireguard/suspended/` | Suspended peer configs |
| `/etc/wireguard/clients/` | Generated client .conf files |
| `/etc/wireguard/wg-manage.conf` | Master configuration |
| `/etc/wireguard/wg-manage.db` | SQLite database |
| `/backup/wg/` | Auto-backups (10 latest) |
| `/usr/local/bin/wg-manage` | CLI entry point |

## Git Versioning

Every change is auto-committed to the git repository at `/home/wg/` with a sequential version tag:

```
v0.00.01-a1b2c3d  →  v0.00.02-f9e8d7c  →  v0.00.03-...
```

## Systemd

```bash
systemctl status wg-manage-sync   # auto-sync on boot
```

## Requirements

- WireGuard (`wireguard-tools`)
- SQLite3 (`sqlite`)
- qrencode (for QR codes)
- git (for versioning)
- Root access

## Future Hubs

Adding US/EU hubs requires only config entries — no code changes:

```bash
WG_HUB_US_SUBNET="10.234.0.0/16"
WG_HUB_US_ENDPOINT="us-central.example.com:51820"
WG_CLIENT_ALLOWED_IPS="... 10.234.0.0/16"
```

---

## About

wg-manage is developed with **mBm AI Assistant** — an AI-powered engineering and operations assistant by [mBm TECHNOLOGY LLC](https://www.mbm.technology) that handles rapid coding, server management, SSH-accessible device management, deployments, and full-stack troubleshooting.

> Try it at: [console.mbm.mn](https://console.mbm.mn)
