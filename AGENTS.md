# AGENTS.md — Developer / AI Assistant Guide

## Project Overview

**wg-manage** is a Bash-based WireGuard peer management CLI for multi-hub deployments. It automates peer lifecycle (create, suspend, delete), IP allocation across hub-specific /16 subnets, client config generation, QR codes, git versioning, and backup — all with zero-downtime `wg syncconf`.

**Repository:** `/home/wg/` on `vpn-server` (10.0.0.1)  
**Git remote:** `https://git.example.com/user/wg-manage.git`

## Key Files

| File | Role |
|---|---|
| `/home/wg/wg-manage.sh` | Main CLI script (~1100 lines, Bash) |
| `/etc/wireguard/wg-manage.conf` | Hub/subnet/endpoint configuration |
| `/etc/wireguard/wg-manage.db` | SQLite database |
| `/etc/wireguard/peers/*.conf` | Active peer WireGuard configs (source of truth for `wg syncconf`) |
| `/etc/wireguard/clients/*.conf` | Generated client configs |
| `/etc/wireguard/suspended/*.conf` | Suspended peer configs |
| `/etc/wireguard/wg0.conf` | Interface-only config (no peers — peers in `peers/`) |
| `/backup/wg/` | Auto-backups (10 latest .tar.gz) |
| `/home/wg/.version` | Auto-incrementing version (`MAJOR.MINOR.PATCH`) |
| `/home/wg/ARCHITECTURE.md` | Topology, routing, subnet design |
| `/home/wg/README.md` | User-facing documentation |

## Architecture Rules

### Never do these (will break things):

1. **Never edit `wg0.conf` directly for peers** — use `wg-manage add/remove/suspend`
2. **Never hardcode an endpoint for client config** — all clients connect to MN hub
3. **Never use `wg syncconf` on SGP** — SGP has its own `Address=` key which `wg syncconf` rejects; use `wg set` for SGP peer changes
4. **Never add comments between `[Peer]` and keys in peer .conf files** — `wg syncconf` is strict and will silently ignore the peer
5. **Never expose private keys in git** — `.gitignore` excludes `*.key` and `wg-manage.db`

### Always do these:

1. **Test with `wg-manage add testpeer` then `remove --force`** — verify full lifecycle works
2. **Run `wg show wg0 | grep -c "^peer:"` after changes** — verify peer count matches expectations
3. **Backup exists before any migration** — check `/etc/wireguard/wg0.conf.bak.*` or `/backup/wg/`
4. **Sync SGP config file to match live config** — file at `/etc/wireguard/wg0.conf` on SGP, live via `wg set`
5. **Commit and tag after every change** — `git_autocommit` runs automatically via the script

## SSH Access

| Server | Hostname | SSH |
|---|---|---|
| MN | vpn-server (localhost) | Direct |
| SGP | sgp-server.example.com | `ssh root@sgr-server.example.com` |

SGP WireGuard config is at `/etc/wireguard/wg0.conf` (monolithic, not managed by wg-manage).  
Only MN hub runs wg-manage. SGP is managed for routing only.

## Hub / Subnet Design

| Hub | Subnet | Status |
|---|---|---|
| MN | `10.232.0.0/16` | Active |
| SGP | `10.233.0.0/16` | Active (IP allocation only; peers connect to MN) |
| US | `10.234.0.0/16` | Future |
| EU | `10.235.0.0/16` | Future |

**Key insight:** All peers connect to MN hub. `--hub` only determines which /16 subnet the IP comes from. Client endpoint is always `vpn-server.example.com:51820`.

## Hub-to-Hub Routing

| Direction | MN Config | Live (wg set) |
|---|---|---|
| MN → SGP | `sgp_south` peer: `AllowedIPs = 10.232.3.0/24, 10.233.0.0/16` | Same as file |
| SGP → MN | File: `mn_central` peer: `AllowedIPs = 10.232.0.0/16, 10.233.0.0/16` | `wg set wg0 peer <MN-pubkey> allowed-ips 10.232.0.0/16,10.233.0.0/16` |

## Database Schema (SQLite)

```
peers:     id, name, public_key, private_key, allowed_ips, hub, region, status, endpoint, dns, description, created_at, updated_at
ip_pool:   id, subnet_a, subnet_b, octet_c, octet_d, peer_id (UNIQUE on subnet_a,b,c,d)
audit_log: id, timestamp, action, peer_name, ip, hub, version
config:    key, value
```

## Script Internals

### Argument Parsing
- All commands: `check_root` first
- `add`: name (required), then options (`--hub`, `--ip`, `--allowed-ips`, `--dns`, `--desc`, `--psk`)
- `list`: first non-flag arg = `search` filter (LIKE '%name%'), optional `active|suspended|all`, `--hub`
- `remove`: `--force` skips confirmation

### IP Allocation
- `find_next_ip(hub)`: scans `10.{subnet_a}.{subnet_b}.{c}.{d}` from `c=0,d=2` to `c=255,d=254`, skipping `c=0,d=1` (server IP)
- Uses `ip_pool` table with UNIQUE constraint
- Performance: O(n²) but fine for <500 peers

### `wg syncconf` Format
- Interface section: ONLY `PrivateKey`, `ListenPort`, `FwMark` (NO `Address`, `PostUp`, `PostDown` — those are wg-quick keys)
- Peer section: `[Peer]` followed immediately by key-value pairs (no comments between `[Peer]` and keys)
- `sync_wg()` filters wg-quick keys and strips comments automatically

### Git Versioning
- `.version` file: `MAJOR.MINOR.PATCH`
- Each commit: PATCH++, tag = `v{MAJOR}.{MINOR}.{PATCH}-{short_hash}`
- `git_autocommit` in `wg-manage.sh` handles auto-commit + tag

## Common Modifications

### Adding a new hub (e.g., US):
1. Add subnet to `/etc/wireguard/wg-manage.conf`:
   ```bash
   WG_HUB_US_SUBNET="10.234.0.0/16"
   WG_HUB_US_ENDPOINT="us-central.example.com:51820"
   ```
2. Add to `WG_CLIENT_ALLOWED_IPS` (space-separated)
3. Add hub-to-hub peer on MN, update SGP routing
4. No script changes needed — `HUB_SUBNET` array auto-loads from config

### Changing default DNS:
Edit `/etc/wireguard/wg-manage.conf`: `WG_DEFAULT_DNS="1.1.1.1,8.8.8.8"`

### Changing client AllowedIPs:
Per-peer: `wg-manage add <name> --allowed-ips "10.232.0.0/16,10.233.0.0/16"`  
Global default: edit `WG_CLIENT_ALLOWED_IPS` in config

### Modifying script behavior:
Script sources `/etc/wireguard/wg-manage.conf` — any variable can be overridden there.

## Testing Checklist

- [ ] `wg-manage info` — server overview works
- [ ] `wg-manage list` — all peers show, live handshakes correct
- [ ] `wg-manage list <search>` — search filtering works
- [ ] `wg-manage show <name>` — details + client config correct
- [ ] `wg-manage add testpeer` — creates peer, correct subnet, correct endpoint
- [ ] `wg-manage add testpeer --hub sgp` — SGP subnet (10.233.x.x), MN endpoint
- [ ] `wg-manage suspend testpeer` — moves to suspended/
- [ ] `wg-manage unsuspend testpeer` — restores correctly
- [ ] `wg-manage qr testpeer` — QR code displays
- [ ] `wg-manage remove testpeer --force` — clean removal
- [ ] `wg show wg0 | grep -c "^peer:"` — peer count unchanged after tests
- [ ] `git log --oneline -3` — auto-commits present
- [ ] `systemctl status wg-manage-sync` — service active
- [ ] SGP routing: `ssh root@sgp-server 'wg show wg0 | grep -A6 <MN-pubkey>'`

## Known Pitfalls

1. **`wg syncconf` rejects `Address=` key** — SGP cannot use `wg syncconf` directly; use `wg set` for peer changes
2. **Duplicate peer names** — `validate_name()` checks DB; error if exists
3. **IP already in use** — checked against `ip_pool` UNIQUE constraint
4. **Stale SGP config file** — `wg set` updates live config but not the file; must also sed the file for persistence
5. **Missing peers after failed sync** — run `wg-manage sync` to rebuild from peer files
6. **Client private key only stored for peers created with `add`** — migrated peers have no key, `show` shows `[no client config]`
