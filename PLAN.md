# wg-manage — WireGuard Peer Management Automation

**Scope:** Full CLI tool for automated WireGuard peer lifecycle management on MN hub server.
**Goal:** Create, delete, suspend/unsuspend peers, generate client configs, QR codes, git versioning, backup.
**Language:** Bash (100% portable, minimal external dependencies)
**Database:** SQLite3 (lightweight, file-based, no daemon required)

---

## 1. Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    wg-manage.sh (CLI)                        │
├──────────────────────────────────────────────────────────────┤
│  add │ remove │ suspend │ unsuspend │ list │ show │ qr │ sync│
├──────────────┬──────────────────┬────────────────────────────┤
│   SQLite DB  │   Filesystem     │     WireGuard Interface    │
│  (metadata,  │  peers/*.conf    │     wg syncconf wg0        │
│   audit_log) │  suspended/*.conf│     (zero-downtime)         │
│  ip_pool     │  clients/*.conf  │                            │
│  config      │  .version        │                            │
└──────────────┴──────────────────┴────────────────────────────┘
```

---

## 2. Directory Structure

```
/home/wg/                              # Git repository root
├── wg-manage.sh                       # Main CLI script
├── .version                           # MAJOR.MINOR.PATCH
├── .gitignore                         # *.key, *.db, *.tar.gz
├── README.md                          # User-facing documentation
├── AGENTS.md                          # Developer/AI assistant guide
├── ARCHITECTURE.md                    # Topology & routing design
├── PLAN.md                            # This document
├── clients -> /etc/wireguard/clients  # Symlink: client configs
├── peers -> /etc/wireguard/peers      # Symlink: peer configs
├── suspended -> /etc/wireguard/suspended  # Symlink: suspended configs
├── wg0.conf -> /etc/wireguard/wg0.conf   # Symlink: interface config
├── patches/
│   └── mask.sed                       # Sensitive data mask patterns
└── sync-github.sh                     # GitHub sync pipeline

/etc/wireguard/
├── wg-manage.conf                     # Hub/subnet/endpoint config
├── wg-manage.db                       # SQLite database
├── wg0.conf                           # Interface-only config
├── public.key                         # Server public key
├── peers/                             # Active peer configs (*.conf)
├── suspended/                         # Suspended peer configs (*.conf)
└── clients/                           # Generated client configs (*.conf)
```

---

## 3. Database Schema

```sql
CREATE TABLE peers (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT UNIQUE NOT NULL,
    public_key  TEXT NOT NULL,
    private_key TEXT DEFAULT '',
    preshared_key TEXT DEFAULT '',
    allowed_ips TEXT NOT NULL,
    hub         TEXT NOT NULL DEFAULT 'mn',
    region      INTEGER NOT NULL DEFAULT 0,
    status      TEXT NOT NULL DEFAULT 'active',
    endpoint    TEXT DEFAULT '',
    dns         TEXT DEFAULT '1.1.1.1,8.8.8.8',
    description TEXT DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (datetime('now','localtime')),
    updated_at  TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);

CREATE TABLE ip_pool (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    subnet_a  INTEGER NOT NULL,
    subnet_b  INTEGER NOT NULL,
    octet_c   INTEGER NOT NULL,
    octet_d   INTEGER NOT NULL,
    peer_id   INTEGER,
    UNIQUE(subnet_a, subnet_b, octet_c, octet_d)
);

CREATE TABLE audit_log (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL DEFAULT (datetime('now','localtime')),
    action    TEXT NOT NULL,
    peer_name TEXT,
    ip        TEXT,
    hub       TEXT,
    version   TEXT
);

CREATE TABLE config (
    key   TEXT PRIMARY KEY,
    value TEXT
);
```

---

## 4. Hub / Subnet Design

| Hub | Subnet | Endpoint | Status |
|---|---|---|---|
| MN | `10.100.0.0/16` | `vpn.example.com:51820` | Active |
| SGP | `10.101.0.0/16` | `sgp.example.com:51820` | Active |
| US | `10.102.0.0/16` | `us.example.com:51820` | Future |
| EU | `10.103.0.0/16` | `eu.example.com:51820` | Future |

**Key rules:**
- All clients connect to MN hub endpoint
- `--hub` only determines which /16 subnet the IP comes from
- Hub-to-hub routing: MN ↔ SGP via WireGuard tunnel

---

## 5. CLI Commands

### Peer Management

```bash
wg-manage add <name> [--hub mn|sgp] [--ip <addr>] [--allowed-ips <cidr>] [--dns <ip>] [--desc <text>] [--psk]
wg-manage remove <name> [--force]
wg-manage suspend <name>
wg-manage unsuspend <name>
wg-manage rename <old-name> <new-name> [--force]
wg-manage ip <name> <new-ip> [--force]
```

### View

```bash
wg-manage list [active|suspended|all] [<search>] [--hub <h>]
wg-manage show <name> [--show-key]
wg-manage qr <name> [--size 10]
wg-manage info
```

### System

```bash
wg-manage sync [--no-commit]
wg-manage backup
wg-manage restore <backup-file> [--force] [--peer <name>]
wg-manage restore --latest [--force] [--peer <name>]
```

---

## 6. IP Allocation Logic

- Scans `10.{subnet_a}.{subnet_b}.{c}.{d}` from `c=0,d=2` to `c=255,d=254`
- Skips `c=0,d=1` (reserved for server IP)
- Checks `ip_pool` table with UNIQUE constraint
- Auto-detects hub from IP subnet
- Performance: O(n²) scan — fine for <500 peers

---

## 7. wg0.conf — Interface Configuration

```ini
[Interface]
PrivateKey = YOUR_PRIVATE_KEY_HERE
Address    = 10.0.0.1/16
ListenPort = 51820
PostUp     = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown   = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT

# ── Peer configs managed by wg-manage ──
# DO NOT add peers here manually.
# Active peers: /etc/wireguard/peers/*.conf
# Suspended:     /etc/wireguard/suspended/*.conf
```

---

## 8. Client Config Generation

```ini
[Interface]
PrivateKey = YOUR_PRIVATE_KEY_HERE
Address    = 10.100.0.4/32
DNS        = 1.1.1.1,8.8.8.8

[Peer]
PublicKey  = YOUR_SERVER_PUBLIC_KEY=
Endpoint   = vpn.example.com:51820
AllowedIPs = 10.100.0.0/16,10.101.0.0/16
PersistentKeepalive = 25
```

---

## 9. wg syncconf — Zero-Downtime Peer Management

Instead of `wg add` / `wg remove` (which cause momentary disruption), wg-manage uses:

```bash
cat /etc/wireguard/wg0.conf /etc/wireguard/peers/*.conf | wg syncconf wg0 /dev/stdin
```

**Key constraint:** `wg syncconf` rejects `Address=` key on interface. SGP server must use `wg set` for peer changes.

---

## 10. Backup & Recovery

- Auto-backup before every mutation: `/backup/wg/backup-YYYYMMDD-HHMMSS.tar.gz`
- Keeps last 10 backups, auto-cleans older ones
- `wg-manage restore --latest --force` for full recovery
- `wg-manage restore --latest --peer <name> --force` for single peer recovery

---

## 11. Sync Pipeline (GitLab → GitHub)

```
master (GitLab, full history)
    │
    ├── git commit + git push origin
    │
    └── pre-push hook → sync-github.sh
         ├── git diff master → patches/mask.sed → auto-mask
         ├── git checkout public → apply masked files → commit
         └── git push github public:main
```

Auto-masked data: domains, endpoints, public/private keys, ports, GitLab URLs.
Public links (mbm.technology, console.mbm.mn) preserved as-is.
