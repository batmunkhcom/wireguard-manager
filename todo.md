# wg-manage — Implementation TODO

## Phase 0: Environment Setup

- [x] `dnf install sqlite -y` — SQLite install
- [x] `mkdir -p /etc/wireguard/{peers,suspended,clients}` — create directories
- [x] `chmod 700` /etc/wireguard/{peers,suspended,clients} — set permissions
- [x] `/backup/wg/` check if exists

---

## Phase 1: SQLite Database

- [x] `wg-manage.sh` in `DB_FILE="/etc/wireguard/wg-manage.db"` define
- [x] `init_db()` function write:
  - [x] `peers` table (id, name, public_key, private_key, preshared_key, allowed_ips, hub, region, status, endpoint, dns, description, created_at, updated_at)
  - [x] `audit_log` table (id, timestamp, action, peer_name, ip, hub, version)
  - [x] `ip_pool` table (id, subnet_a, subnet_b, octet_c, octet_d, peer_id, UNIQUE)
  - [x] `config` table (key PRIMARY KEY, value)
- [x] `db_query()` helper function
- [x] `db_escape()` helper function (protect from SQL injection)

---

## Phase 2: wg0.conf Migration

- [x] Current `wg0.conf`-г `wg0.conf.bak` → create backup
- [x] `wg0.conf` in зөвхөн `[Interface]` section
- [x] `[Interface]` add comment below section: `# ── Peer configs managed by wg-manage ──`

---

## Phase 3: Initial Migration — Peer Extraction

- [x] `migrate_peers()` function write:
  - [x] `wg0.conf.bak`-с peer нэрийг `#<comment>` identify from line
  - [x] `[Peer]` block → `peers/<name>.conf` 
  - [x] Skip zone 1 (10.100.1.x), zone 2 (10.100.2.x) peers (delete)
  - [x] Hub detection: zone 0→mn, zone 3→sgp
- [x] Run migration
- [x] `db_init` call to prepare database
- [x] `peers` tableэд peer бүрийг register
- [x] `ip_pool` tableэд IP бүрийг register
- [x] `config` store hub endpoints in table

---

## Phase 4: Core Functions

### 4.0 Helper Functions
- [x] `check_root()` — check root permissions
- [x] `die()` — show error message and exit
- [x] `confirm()` — confirm from user (y/N)
- [x] `load_config()` — `/etc/wireguard/wg-manage.conf` read (use defaults if missing)
- [x] `get_server_pubkey()` — `/etc/wireguard/public.key` read
- [x] `get_hub_endpoint()` — hub get endpoint by name
- [x] `find_next_ip()` — find lowest available IP in selected zone

### 4.1 Git & Version
- [x] `read_version()` — `.version` read from file
- [x] `bump_version()` — PATCH ++1, `.version`-д write
- [x] `git_autocommit()` function write:
  - [x] `git add -A` (peers/, suspended/, clients/, wg0.conf, .version)
  - [x] commit message create (`[action] peer '<name>' — <detail>`)
  - [x] `git commit -m "$msg"`
  - [x] `git tag "v${ver}-$(git rev-parse --short HEAD)"`

### 4.2 Backup
- [x] `auto_backup()` — `/backup/wg/backup-YYYYMMDD-HHMMSS.tar.gz`
- [x] `cleanup_backups()` — delete old backups (keep last 10)

### 4.3 WireGuard Sync
- [x] `sync_wg()` function:
  - [x] `cat /etc/wireguard/wg0.conf /etc/wireguard/peers/*.conf | wg syncconf wg0 /dev/stdin`
  - [x] On error: `die`

---

## Phase 5: CLI Commands

### 5.1 `add`
- [x] `cmd_add()` — peer create, assign IP, generate config, register in DB, run sync

### 5.2 `remove`
- [x] `cmd_remove()` — peer delete, release IP, clean config

### 5.3 `suspend`
- [x] `cmd_suspend()` — move peer to suspended/, change status

### 5.4 `unsuspend`
- [x] `cmd_unsuspend()` — suspended peer-г restore

### 5.5 `list`
- [x] `cmd_list()` — list all peers, live handshake, filtering

### 5.6 `show`
- [x] `cmd_show()` — peer details, client config, --show-key

### 5.7 `qr`
- [x] `cmd_qr()` — generate QR code

### 5.8 `sync`
- [x] `cmd_sync()` — manual sync

### 5.9 `info`
- [x] `cmd_info()` — system overview

### 5.10 `backup`
- [x] `cmd_backup()` — manual backup

### 5.11 `help`
- [x] `cmd_help()` — help

### 5.12 Additional Commands
- [x] `rename` — rename peer
- [x] `ip` — change peer IP, auto-detect hub
- [x] `restore` — restore peer from backup, single peer via --peer flag

---

## Phase 6: Configuration File

- [x] `/etc/wireguard/wg-manage.conf` create (hub endpoint, DNS, keepalive, backup keep)

---

## Phase 7: Git Repository Setup

- [x] `.gitignore` create (private.key, *.db, *.tar.gz, backup/)
- [x] `.version` create file
- [x] Initial commit: "init: wg-manage — WireGuard peer management automation"
- [x] create symlinks (peers, suspended, clients, wg0.conf → /home/wg/)
- [x] git remote: `https://git.example.com/user/wg-manage.git`

---

## Phase 8: Systemd Integration

- [x] `/etc/systemd/system/wg-manage-sync.service` create
- [x] `systemctl enable wg-manage-sync.service` — auto-sync on boot

---

## Phase 9: Installation

- [x] `ln -sf /home/wg/wg-manage.sh /usr/local/bin/wg-manage`
- [x] `chmod +x /home/wg/wg-manage.sh`
- [x] `wg-manage help` ажиллаж check if exists

---

## Phase 10: Testing

- [x] `wg-manage info` — system info displays correctly
- [x] `wg-manage list` — 31 peers display correctly
- [x] `wg-manage show sgp_south` — details correct
- [x] `wg-manage add testpeer` — create new peer
- [x] `wg-manage suspend testpeer` — run suspend
- [x] `wg-manage unsuspend testpeer` — restore
- [x] `wg-manage remove testpeer --force` — delete
- [x] `wg-manage qr sgp_south` — QR code displays
- [x] `wg show wg0` → peers not deleted, interface UP
- [x] `git log --oneline -5` → commit history correct
- [x] `git tag` → tags formatted correctly
- [x] `/backup/wg/` → backup files created
- [x] `systemctl status wg-manage-sync` → active

---

## Phase 11: Final Cleanup

- [x] `wg0.conf.bak` delete
- [x] remove unnecessary test files
- [x] README.md update
- [x] AGENTS.md (AI assistant guide) write
- [x] ARCHITECTURE.md (topology, routing, subnet дизайн) write
- [x] skills/wg-manage.md (AI skill definition) write

---

## Phase 12: Prometheus / Grafana Monitoring

- [x] `wireguard_metrics.sh` — shell script exporter, node_exporter textfile collector
- [x] 6 per-peer metric: received_bytes_total, sent_bytes_total, handshake_seconds, handshake_age_seconds, connected, info
- [x] 6 summary metric: interface_info, peers_total, peers_connected_total, peers_by_hub_total, suspended_peers_total, exporter_success
- [x] resolve peer_name, hub, status, created_at labels from SQLite DB
- [x] `wireguard-dashboard.json` — 14 chart, 4 row, ready for Grafana import
- [x] `grafana-queries.txt` — all PromQL queries + alert rules
- [x] Cron: `* * * * * /tools/wireguard-exporter/wireguard_metrics.sh`
- [x] Git repo: `https://git.example.com/user/wireguard-exporter.git`
- [x] node_exporter `--collector.textfile.directory` configured
- [x] install exporter on SGP node (wireguard_metrics.sh + cron)
- [x] `wg0.conf`-с fallback for peer name resolution (no DB on SGP)
- [x] `prometheus-alerts.yml` — 7 alert rule
- [x] `wireguard-dashboard.json` — added disconnected peers table
- [ ] enable Prometheus alert rules (add rule_files to prometheus.yml)
- [ ] Grafana dashboard public link/share configure

---

**Total:** 97+ steps, 12 phases — 95 done, 2 remaining
# test sync Tue Jul 21 04:06:52 PM +08 2026


---

## Phase 13: GitHub Public Sync Pipeline

- [x] `patches/mask.sed` — auto-mask patterns (domains, public key, private key, IP)
- [x] `sync-github.sh` — diff-based sync script (`--dry-run`, `--force`)
- [x] Leak scanner — `patches/` check all diff excluding patches/
- [x] GitHub remote via SSH (`git@github.com:user/wireguard-manager.git`)
- [x] `public` orphan branch (for GitHub main)
- [x] Initial push → GitHub main (auto-masked)
- [x] Auto-tracking `.last-github-sync` file — sync only new commits
- [x] sync updates to GitLab master
- [ ] GitHub Actions CI/CD configure
# auto-sync test Tue Jul 21 04:21:25 PM +08 2026
