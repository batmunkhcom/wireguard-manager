# wg-manage Skill

## When to Use

Load this skill when the user asks to:
- Add, remove, suspend, unsuspend WireGuard peers
- View peer list, details, or client configs
- Generate QR codes for WireGuard
- Debug WireGuard connectivity or routing
- Modify hub/subnet configuration
- Perform WireGuard backups or syncs

## Architecture Rules (MUST follow)

1. **All peers connect to MN hub** — endpoint is always `vpn-server.example.com:51820`
2. **`--hub` flag controls IP subnet only**, not connection endpoint:
   - `--hub mn` → IP from `10.100.0.0/16`
   - `--hub sgp` → IP from `10.101.0.0/16`
   - `--hub us` → `10.234.0.0/16` (future)
   - `--hub eu` → `10.235.0.0/16` (future)
3. **Never edit `/etc/wireguard/wg0.conf` directly** — use `wg-manage` commands
4. **Never use `wg syncconf` directly on SGP** — SGP config has `Address=` which syncconf rejects; use `wg set` for SGP peers
5. **Peer .conf files must NOT have comments between `[Peer]` and keys** — `wg syncconf` silently ignores those peers
6. **Test with add/remove after any script change** — `wg-manage add testpeer; wg-manage remove testpeer --force`

## Common Workflows

### Create a Peer
```bash
wg-manage add <name>                      # auto-IP, MN subnet
wg-manage add <name> --hub sgp            # auto-IP, SGP subnet
wg-manage add <name> --ip 10.100.0.77     # custom IP (must be in hub subnet)
wg-manage add <name> --allowed-ips "10.100.0.0/16,10.101.0.0/16"  # custom AllowedIPs
wg-manage add <name> --psk                # with PresharedKey
```

### Lifecycle
```bash
wg-manage suspend <name>       # temp disable (IP preserved)
wg-manage unsuspend <name>     # restore
wg-manage remove <name> --force # permanent delete
```

### View
```bash
wg-manage list                    # all peers
wg-manage list <search>           # search by name
wg-manage list active --hub mn    # filter
wg-manage show <name>             # details + client config
wg-manage show <name> --show-key  # reveal private key
wg-manage qr <name>               # QR code (only for peers created with 'add')
wg-manage info                    # server overview
```

### System
```bash
wg-manage sync                    # rebuild interface from peer files
wg-manage sync --no-commit        # skip git commit
wg-manage backup                  # manual snapshot
```

## Hub-to-Hub Routing

MN ↔ SGP tunnel uses these routes:
- **MN → SGP:** `sgp_south` peer: `AllowedIPs = 10.100.3.0/24, 10.101.0.0/16`
- **SGP → MN:** `mn_central` peer: `AllowedIPs = 10.100.0.0/16, 10.101.0.0/16`

To update SGP routing (since syncconf doesn't work there):
```bash
ssh root@sgr-server.example.com 'wg set wg0 peer YOUR_SERVER_PUBLIC_KEY= allowed-ips 10.100.0.0/16,10.101.0.0/16'
# Also update SGP's /etc/wireguard/wg0.conf file for persistence
```

## Troubleshooting

### Peer not connecting
```bash
wg show wg0 | grep -A8 "<peer-pubkey-first-12-chars>"
# Check: handshake time, endpoint, transfer
```

### Wrong endpoint in client config
```bash
cat /etc/wireguard/clients/<name>.conf | grep Endpoint
# Should be: Endpoint = vpn-server.example.com:51820
```

### Ping fails from MN-connected peer to SGP
1. Check MN routing: `cat /etc/wireguard/peers/sgp_south.conf`
2. Check SGP routing: `ssh root@sgp-server 'wg show wg0 | grep -A6 <MN-pubkey>'`
3. Ensure SGP's `mn_central` AllowedIPs includes the source subnet

### After any sgp_south change
- Update file: `sed -i` on `/etc/wireguard/peers/sgp_south.conf`
- Update live: `wg-manage sync --no-commit`

### Interface empty after error
```bash
wg-manage sync    # rebuilds from peers/ directory
```

## Verification Checklist

After any change:
```bash
wg show wg0 | grep -c "^peer:"     # verify peer count
wg-manage list | tail -3           # verify live status
git log --oneline -1               # verify auto-commit
```

## Files Reference

| File | Purpose |
|---|---|
| `/home/wg/wg-manage.sh` | Main script |
| `/etc/wireguard/wg-manage.conf` | Configuration |
| `/etc/wireguard/wg-manage.db` | SQLite database |
| `/etc/wireguard/peers/` | Active peer configs |
| `/etc/wireguard/clients/` | Generated client configs |
| `/etc/wireguard/suspended/` | Suspended peer configs |
| `/backup/wg/` | Backups |
| `/home/wg/AGENTS.md` | Full developer guide |
| `/home/wg/ARCHITECTURE.md` | Topology details |
| `/home/wg/README.md` | User docs |
