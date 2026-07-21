# wg-manage — Implementation TODO

## Phase 0: Environment Setup

- [x] `dnf install sqlite -y` — SQLite суулгах
- [x] `mkdir -p /etc/wireguard/{peers,suspended,clients}` — шинэ хавтаснууд
- [x] `chmod 700` /etc/wireguard/{peers,suspended,clients} — зөвшөөрлийг тохируулах
- [x] `/backup/wg/` байгаа эсэхийг шалгах

---

## Phase 1: SQLite Database

- [x] `wg-manage.sh` дотор `DB_FILE="/etc/wireguard/wg-manage.db"` тодорхойлох
- [x] `init_db()` функц бичих:
  - [x] `peers` хүснэгт (id, name, public_key, private_key, preshared_key, allowed_ips, hub, region, status, endpoint, dns, description, created_at, updated_at)
  - [x] `audit_log` хүснэгт (id, timestamp, action, peer_name, ip, hub, version)
  - [x] `ip_pool` хүснэгт (id, subnet_a, subnet_b, octet_c, octet_d, peer_id, UNIQUE)
  - [x] `config` хүснэгт (key PRIMARY KEY, value)
- [x] `db_query()` туслах функц
- [x] `db_escape()` туслах функц (SQL injection-с хамгаалах)

---

## Phase 2: wg0.conf Migration

- [x] Одоогийн `wg0.conf`-г `wg0.conf.bak` болгож backup хийх
- [x] `wg0.conf` дотор зөвхөн `[Interface]` хэсгийг үлдээх
- [x] `[Interface]` хэсгийн доор тайлбар нэмэх: `# ── Peer configs managed by wg-manage ──`

---

## Phase 3: Initial Migration — Peer Extraction

- [x] `migrate_peers()` функц бичих:
  - [x] `wg0.conf.bak`-с peer нэрийг `#<comment>` мөрнөөс таних
  - [x] `[Peer]` блок бүрийг `peers/<name>.conf` болгон салгах
  - [x] Bүс 1 (10.232.1.x), бүс 2 (10.232.2.x) peer-үүдийг алгасах (устгах)
  - [x] Hub тодорхойлох: бүс 0→mn, бүс 3→sgp
- [x] Миграци хийх
- [x] `db_init` дуудаж өгөгдлийн санг бэлдэх
- [x] `peers` хүснэгтэд peer бүрийг бүртгэх
- [x] `ip_pool` хүснэгтэд IP бүрийг бүртгэх
- [x] `config` хүснэгтэд hub endpoint-үүдийг хадгалах

---

## Phase 4: Core Functions

### 4.0 Helper Functions
- [x] `check_root()` — root эрх шалгах
- [x] `die()` — алдааны мэдээлэл харуулаад гарах
- [x] `confirm()` — хэрэглэгчээс баталгаажуулах (y/N)
- [x] `load_config()` — `/etc/wireguard/wg-manage.conf` унших (байхгүй бол default утгууд)
- [x] `get_server_pubkey()` — `/etc/wireguard/public.key` унших
- [x] `get_hub_endpoint()` — hub нэрээр endpoint авах
- [x] `find_next_ip()` — сонгосон бүсэд хамгийн бага сул IP олох

### 4.1 Git & Version
- [x] `read_version()` — `.version` файлаас унших
- [x] `bump_version()` — PATCH ++1, `.version`-д бичих
- [x] `git_autocommit()` функц бичих:
  - [x] `git add -A` (peers/, suspended/, clients/, wg0.conf, .version)
  - [x] commit message үүсгэх (`[action] peer '<name>' — <detail>`)
  - [x] `git commit -m "$msg"`
  - [x] `git tag "v${ver}-$(git rev-parse --short HEAD)"`

### 4.2 Backup
- [x] `auto_backup()` — `/backup/wg/backup-YYYYMMDD-HHMMSS.tar.gz`
- [x] `cleanup_backups()` — хуучин backup-уудыг устгах (сүүлийн 10-г үлдээх)

### 4.3 WireGuard Sync
- [x] `sync_wg()` функц:
  - [x] `cat /etc/wireguard/wg0.conf /etc/wireguard/peers/*.conf | wg syncconf wg0 /dev/stdin`
  - [x] Алдаа гарвал `die`

---

## Phase 5: CLI Commands

### 5.1 `add`
- [x] `cmd_add()` — peer үүсгэх, IP олгох, config үүсгэх, DB бүртгэх, sync хийх

### 5.2 `remove`
- [x] `cmd_remove()` — peer устгах, IP суллах, config цэвэрлэх

### 5.3 `suspend`
- [x] `cmd_suspend()` — peer-г suspended/ руу зөөх, status өөрчлөх

### 5.4 `unsuspend`
- [x] `cmd_unsuspend()` — suspended peer-г сэргээх

### 5.5 `list`
- [x] `cmd_list()` — бүх peer-ийн жагсаалт, live handshake, шүүлт

### 5.6 `show`
- [x] `cmd_show()` — peer дэлгэрэнгүй, client config, --show-key

### 5.7 `qr`
- [x] `cmd_qr()` — QR код үүсгэх

### 5.8 `sync`
- [x] `cmd_sync()` — гараар sync хийх

### 5.9 `info`
- [x] `cmd_info()` — системийн тойм мэдээлэл

### 5.10 `backup`
- [x] `cmd_backup()` — гараар backup хийх

### 5.11 `help`
- [x] `cmd_help()` — тусламж

### 5.12 Additional Commands
- [x] `rename` — peer нэр солих
- [x] `ip` — peer IP солих, автомат hub таних
- [x] `restore` — backup-с peer сэргээх, --peer флагаар ганц peer

---

## Phase 6: Configuration File

- [x] `/etc/wireguard/wg-manage.conf` үүсгэх (hub endpoint, DNS, keepalive, backup keep)

---

## Phase 7: Git Repository Setup

- [x] `.gitignore` үүсгэх (private.key, *.db, *.tar.gz, backup/)
- [x] `.version` файл үүсгэх
- [x] Анхны commit: "init: wg-manage — WireGuard peer management automation"
- [x] symlink-ууд үүсгэх (peers, suspended, clients, wg0.conf → /home/wg/)
- [x] git remote: `https://git.example.com/user/wg-manage.git`

---

## Phase 8: Systemd Integration

- [x] `/etc/systemd/system/wg-manage-sync.service` үүсгэх
- [x] `systemctl enable wg-manage-sync.service` — ачааллын үед автомат синк

---

## Phase 9: Installation

- [x] `ln -sf /home/wg/wg-manage.sh /usr/local/bin/wg-manage`
- [x] `chmod +x /home/wg/wg-manage.sh`
- [x] `wg-manage help` ажиллаж байгаа эсэхийг шалгах

---

## Phase 10: Testing

- [x] `wg-manage info` — системийн мэдээлэл зөв харагдах
- [x] `wg-manage list` — 31 peer зөв харагдах
- [x] `wg-manage show sgp_south` — дэлгэрэнгүй зөв
- [x] `wg-manage add testpeer` — шинэ peer үүсгэх
- [x] `wg-manage suspend testpeer` — suspend хийх
- [x] `wg-manage unsuspend testpeer` — сэргээх
- [x] `wg-manage remove testpeer --force` — устгах
- [x] `wg-manage qr sgp_south` — QR код харагдах
- [x] `wg show wg0` → peer-үүд устаагүй, интерфэйс UP
- [x] `git log --oneline -5` → commit түүх зөв
- [x] `git tag` → tag-ууд зөв форматтай
- [x] `/backup/wg/` → backup файлууд үүссэн
- [x] `systemctl status wg-manage-sync` → идэвхтэй

---

## Phase 11: Final Cleanup

- [x] `wg0.conf.bak` устгах
- [x] Шаардлагагүй туршилтын файлуудыг устгах
- [x] README.md шинэчлэх
- [x] AGENTS.md (AI assistant guide) бичих
- [x] ARCHITECTURE.md (топологи, routing, subnet дизайн) бичих
- [x] skills/wg-manage.md (AI skill definition) бичих

---

## Phase 12: Prometheus / Grafana Monitoring

- [x] `wireguard_metrics.sh` — shell script exporter, node_exporter textfile collector
- [x] 6 per-peer metric: received_bytes_total, sent_bytes_total, handshake_seconds, handshake_age_seconds, connected, info
- [x] 6 summary metric: interface_info, peers_total, peers_connected_total, peers_by_hub_total, suspended_peers_total, exporter_success
- [x] SQLite DB-с peer_name, hub, status, created_at label тайлбарлах
- [x] `wireguard-dashboard.json` — 14 chart, 4 row, Grafana import-д бэлэн
- [x] `grafana-queries.txt` — бүх PromQL query + alert rules
- [x] Cron: `* * * * * /tools/wireguard-exporter/wireguard_metrics.sh`
- [x] Git repo: `https://git.example.com/user/wireguard-exporter.git`
- [x] node_exporter `--collector.textfile.directory` тохируулсан
- [x] SGP node дээр exporter суулгах (wireguard_metrics.sh + cron)
- [x] `wg0.conf`-с peer нэр унших fallback (SGP-д DB байхгүй)
- [x] `prometheus-alerts.yml` — 7 alert rule
- [x] `wireguard-dashboard.json` — disconnected peers table нэмсэн
- [ ] Prometheus alert rules идэвхжүүлэх (prometheus.yml-д rule_files нэмэх)
- [ ] Grafana dashboard public link/share тохируулах

---

**Нийт:** 97+ алхам, 12 фаз — 95 хийгдсэн, 2 үлдсэн
# test sync Tue Jul 21 04:06:52 PM +08 2026


---

## Phase 13: GitHub Public Sync Pipeline

- [x] `patches/mask.sed` — auto-mask pattern-үүд (домэйн, public key, private key, IP)
- [x] `sync-github.sh` — diff-based sync скрипт (`--dry-run`, `--force`)
- [x] Leak scanner — `patches/` файлаас бусад бүх diff-г шалгах
- [x] GitHub remote SSH-ээр (`git@github.com:user/wireguard-manager.git`)
- [x] `public` orphan branch (GitHub main-д зориулсан)
- [x] Initial push → GitHub main (аутоматаар mask хийгдсэн)
- [x] Auto-tracking `.last-github-sync` файлаар зөвхөн шинэ commit sync хийх
- [x] GitLab master руу sync шинэчлэл хийх
- [ ] GitHub Actions CI/CD тохируулах
# auto-sync test Tue Jul 21 04:21:25 PM +08 2026
