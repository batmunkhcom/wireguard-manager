#!/bin/bash
# ============================================================
# wg-manage.sh — WireGuard Peer Management Automation
# mBm TECHNOLOGY LLC | www.mbm.technology
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_FILE="/etc/wireguard/wg-manage.db"
WG_CONF="/etc/wireguard/wg0.conf"
PEERS_DIR="/etc/wireguard/peers"
SUSPENDED_DIR="/etc/wireguard/suspended"
CLIENTS_DIR="/etc/wireguard/clients"
BACKUP_DIR="/backup/wg"
VERSION_FILE="$SCRIPT_DIR/.version"
GIT_DIR="/home/wg"
SERVER_PUBLIC_KEY=$(cat /etc/wireguard/public.key 2>/dev/null || echo "")

# ── Default Config ──
WG_DEFAULT_HUB="mn"
WG_DEFAULT_DNS="1.1.1.1,8.8.8.8"
WG_KEEPALIVE=25
WG_BACKUP_KEEP=10
WG_CLIENT_ALLOWED_IPS="10.100.0.0/16 10.101.0.0/16"
WG_HUB_MN_ENDPOINT="vpn.example.com:51820"
WG_HUB_SGP_ENDPOINT="sgp.example.com:51820"
WG_HUB_US_ENDPOINT="us.example.com:51820"
WG_HUB_EU_ENDPOINT="eu.example.com:51820"
WG_HUB_MN_SUBNET="10.100.0.0/16"
WG_HUB_SGP_SUBNET="10.101.0.0/16"
WG_HUB_US_SUBNET="10.102.0.0/16"
WG_HUB_EU_SUBNET="10.103.0.0/16"

# Load user overrides
[ -f /etc/wireguard/wg-manage.conf ] && source /etc/wireguard/wg-manage.conf

# ── Hub ↔ Subnet maps ──
declare -A HUB_SUBNET=([mn]="$WG_HUB_MN_SUBNET" [sgp]="$WG_HUB_SGP_SUBNET" [us]="$WG_HUB_US_SUBNET" [eu]="$WG_HUB_EU_SUBNET")

# ── Colors ──
C_RESET='\033[0m'; C_BOLD='\033[1m'; C_GREEN='\033[0;32m'; C_RED='\033[0;31m'
C_YELLOW='\033[0;33m'; C_CYAN='\033[0;36m'; C_DIM='\033[2m'

# ============================================================
# HELPER FUNCTIONS
# ============================================================
check_root() { [ "$EUID" -eq 0 ] || die "root required — run: sudo wg-manage $*"; }
die()    { echo -e "${C_RED}ERROR:${C_RESET} $*" >&2; exit 1; }
warn()   { echo -e "${C_YELLOW}WARN:${C_RESET}  $*" >&2; }
info()   { echo -e "${C_CYAN}INFO:${C_RESET}  $*"; }
ok()     { echo -e "${C_GREEN}OK:${C_RESET}    $*"; }

confirm() {
    local prompt="${1:-Continue?} [y/N] "
    read -r -p "$prompt" answer
    [[ "$answer" =~ ^[Yy]$ ]] || die "aborted by user"
}

db_escape() { sed "s/'/''/g" <<< "${1:-}"; }
db_query() {
    if [ "$1" = "-separator" ]; then
        sqlite3 -separator "$2" "$DB_FILE" "$3"
    else
        sqlite3 "$DB_FILE" "$1"
    fi
}
db_exists() { [ -f "$DB_FILE" ] && [ "$(db_query "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='peers';")" -gt 0 ]; }

# ============================================================
# DATABASE
# ============================================================
init_db() {
    mkdir -p "$(dirname "$DB_FILE")"
    db_query "
        CREATE TABLE IF NOT EXISTS peers (
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

        CREATE TABLE IF NOT EXISTS audit_log (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL DEFAULT (datetime('now','localtime')),
            action    TEXT NOT NULL,
            peer_name TEXT DEFAULT NULL,
            ip        TEXT DEFAULT NULL,
            hub       TEXT DEFAULT NULL,
            version   TEXT DEFAULT NULL
        );

        CREATE TABLE IF NOT EXISTS ip_pool (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            subnet_a TEXT NOT NULL,
            subnet_b TEXT NOT NULL,
            octet_c  INTEGER NOT NULL,
            octet_d  INTEGER NOT NULL,
            peer_id INTEGER,
            UNIQUE(subnet_a, subnet_b, octet_c, octet_d)
        );

        CREATE TABLE IF NOT EXISTS config (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
    " || die "failed to initialize database"
}

# ============================================================
# IP / SUBNET HELPERS
# ============================================================
subnet_prefix() {
    local hub="$1"
    echo "${HUB_SUBNET[$hub]:-10.232}" | cut -d. -f1-2
}

ip_to_hub() {
    local ip="$1"
    local prefix=$(echo "$ip" | cut -d. -f1-2)
    for h in "${!HUB_SUBNET[@]}"; do
        local hp=$(echo "${HUB_SUBNET[$h]}" | cut -d. -f1-2)
        [ "$prefix" = "$hp" ] && { echo "$h"; return 0; }
    done
    echo ""
    return 1
}

find_next_ip() {
    local hub="$1"
    local prefix=$(subnet_prefix "$hub")
    local used
    for c in $(seq 0 255); do
        for d in $(seq 2 254); do
            [ "$c" -eq 0 ] && [ "$d" -eq 1 ] && continue  # skip server IP x.x.0.1
            used=$(db_query "SELECT COUNT(*) FROM ip_pool WHERE subnet_a='$(echo "$prefix" | cut -d. -f1)' AND subnet_b='$(echo "$prefix" | cut -d. -f2)' AND octet_c=$c AND octet_d=$d;" 2>/dev/null || echo 0)
            [ "$used" -eq 0 ] && { echo "${prefix}.${c}.${d}"; return 0; }
        done
    done
    return 1
}

# ============================================================
# HUB HELPERS
# ============================================================
get_hub_endpoint() {
    local hub="$1"
    case "$hub" in
        mn)  echo "$WG_HUB_MN_ENDPOINT" ;;
        sgp) echo "$WG_HUB_SGP_ENDPOINT" ;;
        us)  echo "$WG_HUB_US_ENDPOINT" ;;
        eu)  echo "$WG_HUB_EU_ENDPOINT" ;;
        *)   echo "" ;;
    esac
}

client_allowed_ips() {
    echo "$WG_CLIENT_ALLOWED_IPS" | tr ' ' ','
}

# ============================================================
# BACKUP
# ============================================================
auto_backup() {
    local ts dest
    ts=$(date +%Y%m%d-%H%M%S)
    dest="$BACKUP_DIR/backup-$ts"
    mkdir -p "$dest"

    cp "$WG_CONF" "$dest/" 2>/dev/null || true
    cp -r "$PEERS_DIR" "$dest/" 2>/dev/null || true
    cp -r "$SUSPENDED_DIR" "$dest/" 2>/dev/null || true
    cp -r "$CLIENTS_DIR" "$dest/" 2>/dev/null || true
    cp "$DB_FILE" "$dest/" 2>/dev/null || true

    tar -czf "${dest}.tar.gz" -C "$BACKUP_DIR" "backup-$ts" 2>/dev/null
    rm -rf "$dest"
    echo "${dest}.tar.gz"
}

cleanup_backups() {
    local keep="${WG_BACKUP_KEEP:-10}"
    local backups count
    backups=($(ls -1t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null))
    count=${#backups[@]}
    if [ "$count" -gt "$keep" ]; then
        for ((i=keep; i<count; i++)); do
            rm -f "${backups[$i]}"
        done
    fi
}

# ============================================================
# GIT & VERSION
# ============================================================
read_version() { cat "$VERSION_FILE" 2>/dev/null || echo "0.00.00"; }

bump_version() {
    local ver major minor patch new_ver
    ver=$(read_version)
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    patch=$(echo "$ver" | cut -d. -f3)
    patch=$((10#${patch} + 1))
    new_ver="${major}.${minor}.$(printf '%02d' "$patch")"
    echo "$new_ver" > "$VERSION_FILE"
    echo "$new_ver"
}

git_autocommit() {
    local action="$1" name="${2:-}" detail="${3:-}"
    cd "$GIT_DIR" || return 1

    # bump version
    local new_ver
    new_ver=$(bump_version)

    # stage changes
    git add peers/ suspended/ clients/ wg0.conf .version 2>/dev/null || true

    # compose message
    local msg
    case "$action" in
        add)       msg="add: peer '$name' — $detail" ;;
        remove)    msg="remove: peer '$name' — $detail" ;;
        suspend)   msg="suspend: peer '$name' — $detail" ;;
        unsuspend) msg="unsuspend: peer '$name' — $detail" ;;
        sync)      msg="sync: full peer rebuild${detail:+ — $detail}" ;;
        rename)    msg="rename: peer '$name' — $detail" ;;
        ip)        msg="ip: peer '$name' — $detail" ;;
        restore)   msg="restore: from backup${detail:+ — $detail}" ;;
        backup)    msg="backup: manual snapshot${detail:+ — $detail}" ;;
        migrate)   msg="migrate: initial peer migration${detail:+ — $detail}" ;;
        *)         msg="$action: $detail" ;;
    esac

    if git diff --cached --quiet 2>/dev/null; then
        # No changes to commit, skip
        :
    else
        git commit -m "$msg" --quiet &>/dev/null || true
    fi

    local short_hash tag
    short_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "0000000")
    tag="v${new_ver}-${short_hash}"
    git tag "$tag" 2>/dev/null || true

    export WG_LAST_VERSION="$tag"
    export WG_LAST_HASH="$short_hash"
}

# ============================================================
# WIREGUARD SYNC
# ============================================================
sync_wg() {
    local tmp errfile
    tmp=$(mktemp)
    errfile=$(mktemp)

    # Build wg-only config (only wg-level keys: PrivateKey, ListenPort, FwMark)
    # Strip wg-quick keys: Address, DNS, MTU, PostUp, PostDown, Table, PreUp, PreDown, SaveConfig
    # Strip comments and blank lines from peer sections (wg syncconf is strict)
    {
        echo "[Interface]"
        grep -E '^(PrivateKey|ListenPort|FwMark)\s*=' "$WG_CONF" 2>/dev/null || true
        echo ""

        for f in "$PEERS_DIR"/*.conf; do
            [ -f "$f" ] || continue
            in_peer=false
            while IFS= read -r line || [ -n "$line" ]; do
                [[ "$line" =~ ^\[Peer\]$ ]] && { in_peer=true; echo "$line"; continue; }
                $in_peer || continue
                [[ "$line" =~ ^\s*# ]] && continue
                [[ "$line" =~ ^\s*$ ]] && continue
                echo "$line"
            done < "$f"
            echo ""
        done
    } > "$tmp"

    if ! wg syncconf wg0 "$tmp" 2>"$errfile"; then
        cat "$errfile" >&2
        rm -f "$tmp" "$errfile"
        die "wg syncconf failed"
    fi
    rm -f "$tmp" "$errfile"
}

# ============================================================
# AUDIT LOG
# ============================================================
audit() {
    local action="$1" peer_name="${2:-}" ip="${3:-}" hub="${4:-}"
    db_query "INSERT INTO audit_log (action, peer_name, ip, hub) VALUES ('$(db_escape "$action")','$(db_escape "$peer_name")','$(db_escape "$ip")','$(db_escape "$hub")');"
}

# ============================================================
# PEER NAME VALIDATION
# ============================================================
validate_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9][-a-zA-Z0-9_]*$ ]] || die "invalid peer name: '$name' (use [a-zA-Z0-9][-a-zA-Z0-9_]*)"
    local exists
    exists=$(db_query "SELECT COUNT(*) FROM peers WHERE name='$(db_escape "$name")';" 2>/dev/null || echo 0)
    [ "$exists" -eq 0 ] || die "peer '$name' already exists"
}

# ============================================================
# COMMAND: add
# ============================================================
cmd_add() {
    local name="" hub="$WG_DEFAULT_HUB" dns="$WG_DEFAULT_DNS" desc="" psk=""
    local allowed_ips custom_ip="" hub_set=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --hub)         hub="$2"; hub_set=true; shift 2 ;;
            --dns)         dns="$2"; shift 2 ;;
            --desc)        desc="$2"; shift 2 ;;
            --psk)         psk=1; shift ;;
            --allowed-ips) allowed_ips="$2"; shift 2 ;;
            --ip)          custom_ip="$2"; shift 2 ;;
            -*)            die "unknown flag: $1" ;;
            *)             [ -z "$name" ] && { name="$1"; shift; continue; }; die "unexpected argument: $1" ;;
        esac
    done

    [ -n "$name" ] || die "usage: wg-manage add <name> [--hub mn|sgp] [--ip <addr>] [--allowed-ips <cidr>] [--dns <ip>] [--desc <text>] [--psk]"
    [ -n "${HUB_SUBNET[$hub]:-}" ] || die "unknown hub: $hub"

    # Default allowed-ips = all active hub subnets
    : "${allowed_ips:=$(client_allowed_ips)}"

    check_root
    init_db
    validate_name "$name"

    # Generate keys
    local privkey pubkey
    privkey=$(wg genkey 2>/dev/null) || die "failed to generate private key"
    pubkey=$(echo "$privkey" | wg pubkey 2>/dev/null) || die "failed to generate public key"

    # Generate PSK if requested
    if [ -n "$psk" ]; then
        psk=$(wg genpsk 2>/dev/null) || die "failed to generate PSK"
    fi

    # Determine IP
    local ip subnet prefix_1 prefix_2 octet_c octet_d
    prefix_1=$(subnet_prefix "$hub" | cut -d. -f1)
    prefix_2=$(subnet_prefix "$hub" | cut -d. -f2)

    if [ -n "$custom_ip" ]; then
        # Validate IP is within hub's subnet
        local ip_hub
        ip_hub=$(ip_to_hub "$custom_ip")
        [ -n "$ip_hub" ] || die "IP $custom_ip not in any known hub subnet"
        [ "$ip_hub" = "$hub" ] || die "IP $custom_ip belongs to hub '$ip_hub', not '$hub'. Use --hub $ip_hub or choose an IP in ${HUB_SUBNET[$hub]}"
        # Validate format
        if [[ ! "$custom_ip" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
            die "invalid IP format: $custom_ip"
        fi
        prefix_1="${BASH_REMATCH[1]}"
        prefix_2="${BASH_REMATCH[2]}"
        octet_c="${BASH_REMATCH[3]}"
        octet_d="${BASH_REMATCH[4]}"
        [ "$octet_c" -le 255 ] || die "invalid IP octet: $custom_ip"
        [ "$octet_d" -ge 1 ] && [ "$octet_d" -le 254 ] || die "host octet out of range (1-254): $custom_ip"
        # Check if IP already used
        local used
        used=$(db_query "SELECT COUNT(*) FROM ip_pool WHERE subnet_a='$prefix_1' AND subnet_b='$prefix_2' AND octet_c=$octet_c AND octet_d=$octet_d;" 2>/dev/null || echo 0)
        [ "$used" -eq 0 ] || die "IP already in use: $custom_ip"
        ip="$custom_ip"
    else
        ip=$(find_next_ip "$hub") || die "no available IPs in ${HUB_SUBNET[$hub]}"
        octet_c=$(echo "$ip" | cut -d. -f3)
        octet_d=$(echo "$ip" | cut -d. -f4)
    fi

    local hub_endpoint
    hub_endpoint="$WG_HUB_MN_ENDPOINT"  # all peers connect to MN

    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    # Backup
    auto_backup > /dev/null

    # Create peer config
    {
        echo "# $name | hub: $hub | created: $now"
        [ -n "$desc" ] && echo "# $desc"
        echo "[Peer]"
        echo "PublicKey = $pubkey"
        [ -n "$psk" ] && echo "PresharedKey = $psk"
        echo "AllowedIPs = ${ip}/32"
        echo "PersistentKeepalive = $WG_KEEPALIVE"
    } > "$PEERS_DIR/${name}.conf"
    chmod 600 "$PEERS_DIR/${name}.conf"

    # Create client config
    {
        echo "[Interface]"
        echo "PrivateKey = $privkey"
        echo "Address = ${ip}/32"
        echo "#DNS = $dns"
        echo ""
        echo "[Peer]"
        echo "PublicKey = $SERVER_PUBLIC_KEY"
        echo "Endpoint = $hub_endpoint"
        echo "AllowedIPs = $allowed_ips"
        echo "PersistentKeepalive = $WG_KEEPALIVE"
    } > "$CLIENTS_DIR/${name}.conf"
    chmod 600 "$CLIENTS_DIR/${name}.conf"

    # Register in DB
    local esc_name esc_pub esc_priv esc_psk esc_ip esc_hub esc_dns esc_desc
    esc_name=$(db_escape "$name")
    esc_pub=$(db_escape "$pubkey")
    esc_priv=$(db_escape "$privkey")
    esc_psk=$(db_escape "$psk")
    esc_ip=$(db_escape "${ip}/32")
    esc_hub=$(db_escape "$hub")
    esc_dns=$(db_escape "$dns")
    esc_desc=$(db_escape "$desc")

    db_query "INSERT INTO peers (name,public_key,private_key,preshared_key,allowed_ips,hub,region,status,dns,description) VALUES ('$esc_name','$esc_pub','$esc_priv','$esc_psk','$esc_ip','$esc_hub',0,'active','$esc_dns','$esc_desc');"
    local peer_id
    peer_id=$(db_query "SELECT id FROM peers WHERE name='$esc_name';")
    db_query "INSERT INTO ip_pool (subnet_a,subnet_b,octet_c,octet_d,region,octet,peer_id) VALUES ('$prefix_1','$prefix_2',$octet_c,$octet_d,0,0,$peer_id);"

    # Sync & commit
    sync_wg
    audit "add" "$name" "$ip" "$hub"
    git_autocommit "add" "$name" "hub=$hub ip=${ip}/32"

    echo -e "${C_GREEN}✓${C_RESET} Peer created: ${C_BOLD}$name${C_RESET}"
    echo "  IP:       ${ip}/32   (subnet: ${HUB_SUBNET[$hub]})"
    echo "  Hub:      $hub"
    echo "  Endpoint: $hub_endpoint"
    echo "  Client:   $CLIENTS_DIR/${name}.conf"
    echo "  Version:  ${WG_LAST_VERSION:-?}"
}

# ============================================================
# COMMAND: remove
# ============================================================
cmd_remove() {
    local name="" force=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=true; shift ;;
            *) name="$1"; shift ;;
        esac
    done
    [ -n "$name" ] || die "usage: wg-manage remove <name> [--force]"

    check_root
    local exists
    exists=$(db_query "SELECT COUNT(*) FROM peers WHERE name='$(db_escape "$name")';")
    [ "$exists" -gt 0 ] || die "peer '$name' not found"

    $force || confirm "Remove peer '$name'? This cannot be undone. [y/N] "

    auto_backup > /dev/null

    # Gather info for audit
    local ip hub
    ip=$(db_query "SELECT allowed_ips FROM peers WHERE name='$(db_escape "$name")';")
    hub=$(db_query "SELECT hub FROM peers WHERE name='$(db_escape "$name")';")

    # Remove files
    rm -f "$PEERS_DIR/${name}.conf" "$SUSPENDED_DIR/${name}.conf" "$CLIENTS_DIR/${name}.conf"

    # Remove from DB
    local esc_name
    esc_name=$(db_escape "$name")
    db_query "DELETE FROM ip_pool WHERE peer_id=(SELECT id FROM peers WHERE name='$esc_name');"
    db_query "DELETE FROM peers WHERE name='$esc_name';"

    sync_wg
    audit "remove" "$name" "$ip" "$hub"
    git_autocommit "remove" "$name" "ip=$ip hub=$hub"

    ok "peer '$name' removed (version: ${WG_LAST_VERSION:-?})"
}

# ============================================================
# COMMAND: suspend
# ============================================================
cmd_suspend() {
    local name="${1:-}"
    [ -n "$name" ] || die "usage: wg-manage suspend <name>"

    check_root
    local status
    status=$(db_query "SELECT status FROM peers WHERE name='$(db_escape "$name")';")
    [ "$status" = "active" ] || die "peer '$name' is already $status (not active)"
    [ -f "$PEERS_DIR/${name}.conf" ] || die "peer config for '$name' not found in $PEERS_DIR/"

    auto_backup > /dev/null

    mv "$PEERS_DIR/${name}.conf" "$SUSPENDED_DIR/${name}.conf"
    db_query "UPDATE peers SET status='suspended', updated_at=datetime('now','localtime') WHERE name='$(db_escape "$name")';"

    sync_wg
    local ip hub
    ip=$(db_query "SELECT allowed_ips FROM peers WHERE name='$(db_escape "$name")';")
    hub=$(db_query "SELECT hub FROM peers WHERE name='$(db_escape "$name")';")
    audit "suspend" "$name" "$ip" "$hub"
    git_autocommit "suspend" "$name" "ip=$ip hub=$hub"

    ok "peer '$name' suspended (version: ${WG_LAST_VERSION:-?})"
}

# ============================================================
# COMMAND: unsuspend
# ============================================================
cmd_unsuspend() {
    local name="${1:-}"
    [ -n "$name" ] || die "usage: wg-manage unsuspend <name>"

    check_root
    local status
    status=$(db_query "SELECT status FROM peers WHERE name='$(db_escape "$name")';")
    [ "$status" = "suspended" ] || die "peer '$name' is not suspended (status: $status)"
    [ -f "$SUSPENDED_DIR/${name}.conf" ] || die "suspended config for '$name' not found"

    auto_backup > /dev/null

    mv "$SUSPENDED_DIR/${name}.conf" "$PEERS_DIR/${name}.conf"
    db_query "UPDATE peers SET status='active', updated_at=datetime('now','localtime') WHERE name='$(db_escape "$name")';"

    sync_wg
    local ip hub
    ip=$(db_query "SELECT allowed_ips FROM peers WHERE name='$(db_escape "$name")';")
    hub=$(db_query "SELECT hub FROM peers WHERE name='$(db_escape "$name")';")
    audit "unsuspend" "$name" "$ip" "$hub"
    git_autocommit "unsuspend" "$name" "ip=$ip hub=$hub"

    ok "peer '$name' unsuspended (version: ${WG_LAST_VERSION:-?})"
}

# ============================================================
# COMMAND: rename
# ============================================================
cmd_rename() {
    local old_name="" new_name="" force=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=true; shift ;;
            -*)      shift ;;
            *)       [ -z "$old_name" ] && { old_name="$1"; shift; continue; }
                     [ -z "$new_name" ] && { new_name="$1"; shift; continue; }
                     die "unexpected argument: $1" ;;
        esac
    done
    [ -n "$old_name" ] && [ -n "$new_name" ] || die "usage: wg-manage rename <old-name> <new-name> [--force]"

    check_root
    init_db

    # Validate old peer exists
    local esc_old peer_status
    esc_old=$(db_escape "$old_name")
    local exists
    exists=$(db_query "SELECT COUNT(*) FROM peers WHERE name='$esc_old';")
    [ "$exists" -gt 0 ] || die "peer '$old_name' not found"
    peer_status=$(db_query "SELECT status FROM peers WHERE name='$esc_old';")

    # Validate new name
    [[ "$new_name" =~ ^[a-zA-Z0-9][-a-zA-Z0-9_]*$ ]] || die "invalid peer name: '$new_name' (use [a-zA-Z0-9][-a-zA-Z0-9_]*)"
    local new_exists
    new_exists=$(db_query "SELECT COUNT(*) FROM peers WHERE name='$(db_escape "$new_name")';")
    [ "$new_exists" -eq 0 ] || die "peer '$new_name' already exists"

    $force || confirm "Rename peer '$old_name' to '$new_name'? [y/N] "

    auto_backup > /dev/null

    # Rename config files
    case "$peer_status" in
        active)
            [ -f "$PEERS_DIR/${old_name}.conf" ] && mv "$PEERS_DIR/${old_name}.conf" "$PEERS_DIR/${new_name}.conf"
            ;;
        suspended)
            [ -f "$SUSPENDED_DIR/${old_name}.conf" ] && mv "$SUSPENDED_DIR/${old_name}.conf" "$SUSPENDED_DIR/${new_name}.conf"
            ;;
    esac
    [ -f "$CLIENTS_DIR/${old_name}.conf" ] && mv "$CLIENTS_DIR/${old_name}.conf" "$CLIENTS_DIR/${new_name}.conf"

    # Update comment line in peer/suspended config
    local conf_file
    if [ "$peer_status" = "suspended" ]; then
        conf_file="$SUSPENDED_DIR/${new_name}.conf"
    else
        conf_file="$PEERS_DIR/${new_name}.conf"
    fi
    if [ -f "$conf_file" ]; then
        sed -i "s/^# ${old_name} /# ${new_name} /" "$conf_file"
    fi

    # Update DB
    local esc_new
    esc_new=$(db_escape "$new_name")
    db_query "UPDATE peers SET name='$esc_new', updated_at=datetime('now','localtime') WHERE name='$esc_old';"
    db_query "UPDATE audit_log SET peer_name='$esc_new' WHERE peer_name='$esc_old';"

    # Sync if active
    if [ "$peer_status" = "active" ]; then
        sync_wg
    fi

    local ip hub
    ip=$(db_query "SELECT allowed_ips FROM peers WHERE name='$esc_new';")
    hub=$(db_query "SELECT hub FROM peers WHERE name='$esc_new';")
    audit "rename" "${old_name}→${new_name}" "$ip" "$hub"
    git_autocommit "rename" "$new_name" "from=$old_name ip=$ip hub=$hub"

    ok "peer '$old_name' renamed to '$new_name' (version: ${WG_LAST_VERSION:-?})"
}

# ============================================================
# COMMAND: ip
# ============================================================
cmd_ip() {
    local name="" new_ip="" force=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=true; shift ;;
            -*)      shift ;;
            *)       [ -z "$name" ] && { name="$1"; shift; continue; }
                     [ -z "$new_ip" ] && { new_ip="$1"; shift; continue; }
                     die "unexpected argument: $1" ;;
        esac
    done
    [ -n "$name" ] && [ -n "$new_ip" ] || die "usage: wg-manage ip <name> <new-ip> [--force]"

    check_root
    init_db

    # Validate peer exists
    local esc_name old_ip old_hub peer_status
    esc_name=$(db_escape "$name")
    local exists
    exists=$(db_query "SELECT COUNT(*) FROM peers WHERE name='$esc_name';")
    [ "$exists" -gt 0 ] || die "peer '$name' not found"

    old_ip=$(db_query "SELECT allowed_ips FROM peers WHERE name='$esc_name';")
    old_hub=$(db_query "SELECT hub FROM peers WHERE name='$esc_name';")
    peer_status=$(db_query "SELECT status FROM peers WHERE name='$esc_name';")
    local old_ip_clean="${old_ip%/32}"

    # Validate new IP format
    if [[ ! "$new_ip" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        die "invalid IP format: $new_ip"
    fi
    local prefix_1="${BASH_REMATCH[1]}" prefix_2="${BASH_REMATCH[2]}"
    local octet_c="${BASH_REMATCH[3]}" octet_d="${BASH_REMATCH[4]}"
    [ "$prefix_1" -le 255 ] && [ "$prefix_2" -le 255 ] || die "invalid IP octet: $new_ip"
    [ "$octet_c" -le 255 ] || die "invalid IP octet: $new_ip"
    [ "$octet_d" -ge 1 ] && [ "$octet_d" -le 254 ] || die "host octet out of range (1-254): $new_ip"

    # Determine new hub from IP
    local new_hub
    new_hub=$(ip_to_hub "$new_ip")
    [ -n "$new_hub" ] || die "IP $new_ip not in any known hub subnet: ${!HUB_SUBNET[*]}"

    # Check if new IP is already in use (by another peer)
    local used
    used=$(db_query "SELECT COUNT(*) FROM ip_pool WHERE subnet_a='$prefix_1' AND subnet_b='$prefix_2' AND octet_c=$octet_c AND octet_d=$octet_d AND peer_id != (SELECT id FROM peers WHERE name='$esc_name');")
    [ "$used" -eq 0 ] || die "IP already in use: $new_ip"

    [ "$old_ip_clean" = "$new_ip" ] && die "peer '$name' already has IP $new_ip"

    # Confirm
    local hub_msg=""
    [ "$old_hub" != "$new_hub" ] && hub_msg=" (hub: $old_hub → $new_hub)"

    $force || confirm "Change IP of '$name' from $old_ip_clean to $new_ip${hub_msg}? [y/N] "

    auto_backup > /dev/null

    # Update peer config
    local conf_file
    if [ "$peer_status" = "suspended" ]; then
        conf_file="$SUSPENDED_DIR/${name}.conf"
    else
        conf_file="$PEERS_DIR/${name}.conf"
    fi
    if [ -f "$conf_file" ]; then
        sed -i "s|^AllowedIPs = .*|AllowedIPs = ${new_ip}/32|" "$conf_file"
        [ "$old_hub" != "$new_hub" ] && sed -i "s/ hub: ${old_hub} |/ hub: ${new_hub} |/" "$conf_file" 2>/dev/null || true
    fi

    # Update client config
    if [ -f "$CLIENTS_DIR/${name}.conf" ]; then
        sed -i "s|^Address = .*|Address = ${new_ip}/32|" "$CLIENTS_DIR/${name}.conf"
    fi

    # Update DB
    local esc_new_ip esc_new_hub
    esc_new_ip=$(db_escape "${new_ip}/32")
    esc_new_hub=$(db_escape "$new_hub")
    db_query "UPDATE peers SET allowed_ips='$esc_new_ip', hub='$esc_new_hub', updated_at=datetime('now','localtime') WHERE name='$esc_name';"

    # Update ip_pool
    db_query "DELETE FROM ip_pool WHERE peer_id=(SELECT id FROM peers WHERE name='$esc_name');"
    db_query "INSERT INTO ip_pool (subnet_a,subnet_b,octet_c,octet_d,peer_id) VALUES ('$prefix_1','$prefix_2',$octet_c,$octet_d,(SELECT id FROM peers WHERE name='$esc_name'));"

    # Sync if active
    if [ "$peer_status" = "active" ]; then
        sync_wg
    fi

    audit "ip-change" "$name" "${old_ip_clean}→${new_ip}" "$new_hub"
    git_autocommit "ip" "$name" "from=$old_ip_clean to=$new_ip hub=$old_hub→$new_hub"

    ok "peer '$name' IP changed: $old_ip_clean → $new_ip (hub: $new_hub)"
}

# ============================================================
# COMMAND: list
# ============================================================
cmd_list() {
    local filter="all" hub_filter="" search=""

    while [ $# -gt 0 ]; do
        case "$1" in
            active|suspended|all) filter="$1"; shift ;;
            --hub)   hub_filter="$2"; shift 2 ;;
            -*)       shift ;;
            *)        search="$1"; shift ;;
        esac
    done

    init_db

    # Build WHERE clause for SQLite query
    local where="1=1"
    case "$filter" in
        active)    where="$where AND status='active'" ;;
        suspended) where="$where AND status='suspended'" ;;
    esac
    [ -n "$hub_filter" ] && where="$where AND hub='$(db_escape "$hub_filter")'"
    [ -n "$search" ] && where="$where AND name LIKE '%$(db_escape "$search")%'"

    # Get peers from DB
    local peers_data
    peers_data=$(db_query -separator '|' "SELECT name,public_key,allowed_ips,hub,status FROM peers WHERE $where ORDER BY hub, allowed_ips;")

    if [ -z "$peers_data" ]; then
        echo -e "${C_DIM}No peers found.${C_RESET}"
        return 0
    fi

    # Get live data from wg for active peer matching
    declare -A wg_endpoint wg_handshake wg_rx wg_tx wg_active
    local first=true
    while IFS=$'\t' read -r pub psk ep allowed hs rx tx ka; do
        $first && { first=false; continue; }  # skip interface line
        wg_endpoint["$pub"]="$ep"
        wg_handshake["$pub"]="$hs"
        wg_rx["$pub"]="$rx"
        wg_tx["$pub"]="$tx"
        wg_active["$pub"]=1
    done < <(wg show wg0 dump 2>/dev/null)

    # Print header
    printf "${C_BOLD}%-7s %-20s %-20s %-5s %-28s${C_RESET}\n" "STATUS" "NAME" "IP" "HUB" "HANDSHAKE/ENDPOINT"
    printf "%.0s─" $(seq 1 85); echo ""

    local active_count=0 suspended_count=0 hub_count=0

    while IFS='|' read -r name pubkey ip hub status; do
        [ -z "$name" ] && continue
        local ip_clean="${ip%/32}"
        local s_mark s_color s_text endpoint_text detail

        if [ -n "${wg_active[$pubkey]:-}" ]; then
            s_mark="●"; s_color="$C_GREEN"; s_text="ACTIVE"
            active_count=$((active_count + 1))

            # Check if hub (has fixed endpoint or is known hub)
            local ep="${wg_endpoint[$pubkey]}"
            local hs="${wg_handshake[$pubkey]}"

            if [ -n "${wg_endpoint[$pubkey]:-}" ] && [ "${wg_endpoint[$pubkey]}" != "(none)" ]; then
                # Has endpoint in live data
                endpoint_text="${wg_endpoint[$pubkey]}"
            elif [ -n "${endpoint_text:-}" ]; then
                :  # from DB
            fi

            if [ "$hs" != "0" ] && [ -n "$hs" ]; then
                local sec=$(( $(date +%s) - hs ))
                if [ $sec -lt 60 ]; then
                    detail="${sec}s ago"
                elif [ $sec -lt 3600 ]; then
                    detail="$((sec/60))m ago"
                elif [ $sec -lt 86400 ]; then
                    detail="$((sec/3600))h ago"
                else
                    detail="$((sec/86400))d ago"
                fi
            else
                detail="never"
            fi
        elif [ "$status" = "suspended" ]; then
            s_mark="◌"; s_color="$C_YELLOW"; s_text="SUSP"
            suspended_count=$((suspended_count + 1))
            detail="—"
        else
            s_mark="○"; s_color="$C_DIM"; s_text="IDLE"
            active_count=$((active_count + 1))
            detail="no handshake"
        fi

        # Check if hub (region x.x.x.1, non-MN hub)
        local last_octet="${ip_clean##*.}"
        if [ "$last_octet" -eq 1 ] && [ "$hub" != "mn" ] && [ -n "${wg_endpoint[$pubkey]:-}" ] && [ "${wg_endpoint[$pubkey]}" != "(none)" ]; then
            s_mark="⬡"; s_color="$C_CYAN"; s_text="HUB"
            hub_count=$((hub_count + 1))
            active_count=$((active_count - 1))
            [ "$status" != "suspended" ] && detail="${wg_endpoint[$pubkey]}"
        fi

        printf "${s_color}%-7s${C_RESET} %-20s %-20s %-5s %-28s\n" \
            "$s_mark $s_text" "$name" "$ip" "$hub" "$detail"
    done <<< "$peers_data"

    printf "%.0s─" $(seq 1 85); echo ""
    echo -e "${C_BOLD}Total:${C_RESET} $((active_count + suspended_count + hub_count)) ($active_count active, $suspended_count suspended, $hub_count hubs)"
}

# ============================================================
# COMMAND: show
# ============================================================
cmd_show() {
    local name="${1:-}" show_key=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --show-key) show_key=true; shift ;;
            *) name="$1"; shift ;;
        esac
    done
    [ -n "$name" ] || die "usage: wg-manage show <name> [--show-key]"

    init_db
    local esc_name
    esc_name=$(db_escape "$name")

    local peer_data
    peer_data=$(db_query -separator '|' "SELECT name,public_key,private_key,preshared_key,allowed_ips,hub,region,status,endpoint,dns,description,created_at,updated_at FROM peers WHERE name='$esc_name';")
    [ -n "$peer_data" ] || die "peer '$name' not found"

    IFS='|' read -r p_name p_pub p_priv p_psk p_ip p_hub p_region p_status p_endpoint p_dns p_desc p_created p_updated <<< "$peer_data"

    echo -e "${C_BOLD}═══ Peer: $p_name ═══${C_RESET}"
    echo "  Status:       $([ "$p_status" = "active" ] && echo -e "${C_GREEN}● Active${C_RESET}" || echo -e "${C_YELLOW}◌ Suspended${C_RESET}")"
    echo "  Public Key:   $p_pub"
    [ -n "$p_psk" ] && echo "  Preshared Key: $p_psk"
    echo "  Allowed IP:   $p_ip"
    echo "  Subnet:       ${HUB_SUBNET[$p_hub]:-?}"
    echo "  Hub:          $p_hub"
    [ -n "$p_endpoint" ] && echo "  Endpoint:     $p_endpoint"
    [ -n "$p_desc" ] && echo "  Description:  $p_desc"
    echo "  DNS:          $p_dns"
    echo "  Created:      $p_created"
    echo "  Updated:      $p_updated"

    # Live status from wg
    if [ "$p_status" = "active" ]; then
        local live
        live=$(wg show wg0 dump 2>/dev/null | grep -F "$p_pub" || true)
        if [ -n "$live" ]; then
            IFS=$'\t' read -r _ _ ep _ hs rx tx _ <<< "$live"
            echo ""
            local sec=$(( $(date +%s) - hs ))
            local hs_text
            if [ "$hs" = "0" ] || [ -z "$hs" ]; then
                hs_text="never"
            elif [ $sec -lt 60 ]; then
                hs_text="${sec}s ago"
            elif [ $sec -lt 3600 ]; then
                hs_text="$((sec/60))m ago"
            elif [ $sec -lt 86400 ]; then
                hs_text="$((sec/3600))h ago"
            else
                hs_text="$((sec/86400))d ago"
            fi
            echo -e "  ${C_CYAN}Live:${C_RESET}"
            echo "    Endpoint:       ${ep:-none}"
            echo "    Last Handshake: $hs_text"
            echo "    Transfer:       $(numfmt --to=iec 2>/dev/null <<< "$rx" || echo "$rx") rx / $(numfmt --to=iec 2>/dev/null <<< "$tx" || echo "$tx") tx"
        fi
    fi

    # Client config
    local client_file="$CLIENTS_DIR/${name}.conf"
    if [ -f "$client_file" ]; then
        echo ""
        echo -e "  ${C_BOLD}═══ Client Config ($client_file) ═══${C_RESET}"
        local in_interface=false
        while IFS= read -r line; do
            if $show_key; then
                echo "  $line"
            else
                if [[ "$line" =~ ^PrivateKey ]]; then
                    echo "  PrivateKey = (hidden, use --show-key to reveal)"
                else
                    echo "  $line"
                fi
            fi
        done < "$client_file"
    else
        echo ""
        echo -e "  ${C_DIM}[no client config file — private key not stored]${C_RESET}"
    fi
}

# ============================================================
# COMMAND: qr
# ============================================================
cmd_qr() {
    local name="${1:-}" size=10
    while [ $# -gt 0 ]; do
        case "$1" in
            --size) size="$2"; shift 2 ;;
            *) name="$1"; shift ;;
        esac
    done
    [ -n "$name" ] || die "usage: wg-manage qr <name> [--size 10]"

    local client_file="$CLIENTS_DIR/${name}.conf"
    [ -f "$client_file" ] || die "client config not found for '$name' (private key not stored for migrated peers)"

    which qrencode &>/dev/null || die "qrencode not installed"

    echo ""
    echo -e "${C_BOLD}═══ QR Code: $name ═══${C_RESET}"
    echo "  Scan with WireGuard mobile app"
    echo ""

    # Strip [Interface] header from output (it's in the conf)
    qrencode -t ANSIUTF8 -s "$size" < "$client_file" 2>/dev/null || die "qrencode failed"

    echo ""
    echo -e "${C_DIM}  Endpoint: $(grep 'Endpoint' "$client_file" | sed 's/.*= //')${C_RESET}"
    echo -e "${C_DIM}  IP:       $(grep 'Address' "$client_file" | sed 's/.*= //')${C_RESET}"
}

# ============================================================
# COMMAND: sync
# ============================================================
cmd_sync() {
    local no_commit=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-commit) no_commit=true; shift ;;
            *) shift ;;
        esac
    done

    check_root
    sync_wg

    if $no_commit; then
        ok "peers synced to wg0 (no commit)"
    else
        init_db
        local count
        count=$(db_query "SELECT COUNT(*) FROM peers WHERE status='active';")
        audit "sync" "" "" ""
        git_autocommit "sync" "" "${count} active peers"
        ok "peers synced to wg0 (version: ${WG_LAST_VERSION:-?})"
    fi
}

# ============================================================
# COMMAND: info
# ============================================================
cmd_info() {
    init_db

    echo -e "${C_BOLD}═══ WireGuard Hub ═══${C_RESET}"
    echo "  Interface:    $(ip -br link show wg0 | awk '{print $2,$3}')"
    echo "  Listen Port:  2700"
    echo "  Server IP:    $(ip -4 addr show wg0 | grep -oP 'inet \K[^ ]+')"
    echo "  Public Key:   $SERVER_PUBLIC_KEY"
    echo ""

    local active suspended total
    active=$(db_query "SELECT COUNT(*) FROM peers WHERE status='active';")
    suspended=$(db_query "SELECT COUNT(*) FROM peers WHERE status='suspended';")
    total=$((active + suspended))
    echo "  Peers:        $total total ($active active, $suspended suspended)"

    # Hub status
    echo ""
    echo -e "${C_BOLD}  Hubs:${C_RESET}"
    local hubs
    hubs=$(db_query -separator '|' "SELECT name,hub,allowed_ips,public_key FROM peers WHERE (allowed_ips LIKE '%.1/32' OR endpoint != '') ORDER BY hub;")
    if [ -n "$hubs" ]; then
        while IFS='|' read -r h_name h_hub h_ip h_pub; do
            [ -z "$h_name" ] && continue
            local hs_text
            local live
            live=$(wg show wg0 dump 2>/dev/null | grep -F "$h_pub" || true)
            if [ -n "$live" ]; then
                IFS=$'\t' read -r _ _ ep _ hs rx tx _ <<< "$live"
                if [ "$hs" != "0" ] && [ -n "$hs" ]; then
                    local sec=$(( $(date +%s) - hs ))
                    hs_text="$((sec/60))m ago (${ep})"
                else
                    hs_text="disconnected"
                fi
            else
                hs_text="not in live config"
            fi
            printf "    %-16s %-4s %-18s %s\n" "$h_name" "$h_hub" "$h_ip" "$hs_text"
        done <<< "$hubs"
    else
        echo "    (none)"
    fi

    echo ""
    echo "  Version:      ${WG_LAST_VERSION:-$(read_version)}"
    echo "  DB:           $DB_FILE ($(db_query "SELECT COUNT(*) FROM peers;") peers)"

    local backup_count
    backup_count=$(ls -1 "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | wc -l)
    local latest_backup
    latest_backup=$(ls -1t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | head -1)
    echo "  Backups:      $BACKUP_DIR/ ($backup_count files${latest_backup:+, latest: $(basename "$latest_backup")})"
}

# ============================================================
# COMMAND: backup
# ============================================================
cmd_backup() {
    check_root
    local dest
    dest=$(auto_backup)
    cleanup_backups
    ok "backup saved: $dest"

    if [ -d "$GIT_DIR/.git" ]; then
        git_autocommit "backup" "" "manual @ $(date '+%Y-%m-%d %H:%M:%S')"
    fi
}

# ============================================================
# COMMAND: restore
# ============================================================
cmd_restore() {
    local backup_file="" use_latest=false force=false peer_name=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --latest) use_latest=true; shift ;;
            --force)  force=true; shift ;;
            --peer)   peer_name="$2"; shift 2 ;;
            -*)       shift ;;
            *)        backup_file="$1"; shift ;;
        esac
    done

    if $use_latest; then
        backup_file=$(ls -1t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | head -1)
        [ -n "$backup_file" ] || die "no backups found in $BACKUP_DIR/"
    fi
    [ -n "$backup_file" ] || die "usage: wg-manage restore <backup-file> [--force] | wg-manage restore --latest [--force] [--peer <name>]"
    [ -f "$backup_file" ] || die "backup file not found: $backup_file"

    check_root
    init_db

    # Show backup info
    local bak_name bak_size bak_date
    bak_name=$(basename "$backup_file")
    bak_size=$(du -h "$backup_file" | cut -f1)
    bak_date=$(stat -c '%y' "$backup_file" 2>/dev/null | cut -d. -f1 || echo "unknown")
    info "restore source: $bak_name ($bak_size, $bak_date)"

    if [ -n "$peer_name" ]; then
        $force || confirm "Restore peer '$peer_name' from backup '$bak_name'? [y/N] "
    else
        $force || confirm "Restore from this backup? This will overwrite current peer configs. [y/N] "
    fi

    # Auto-backup current state first (safety net)
    local pre_restore_backup
    pre_restore_backup=$(auto_backup)
    info "current state backed up: $(basename "$pre_restore_backup")"

    # Extract backup
    local tmpdir
    tmpdir=$(mktemp -d)
    if ! tar -xzf "$backup_file" -C "$tmpdir" 2>/dev/null; then
        rm -rf "$tmpdir"
        die "failed to extract backup (corrupted?)"
    fi

    # Find the inner directory
    local inner
    inner=$(ls -d "$tmpdir"/backup-*/ 2>/dev/null | head -1)
    if [ -z "$inner" ]; then
        rm -rf "$tmpdir"
        die "invalid backup structure (no backup-* directory found)"
    fi

    # ── Single-peer restore ──
    if [ -n "$peer_name" ]; then
        restore_single_peer "$inner" "$peer_name" "$bak_name"
        rm -rf "$tmpdir"
        return 0
    fi

    # ── Full restore ──
    local restored_peers=0 restored_suspended=0 restored_clients=0
    if [ -d "$inner/peers" ] && [ "$(ls -A "$inner/peers" 2>/dev/null)" ]; then
        rm -f "$PEERS_DIR"/*.conf
        cp "$inner/peers"/*.conf "$PEERS_DIR/" 2>/dev/null || true
        chmod 600 "$PEERS_DIR"/*.conf 2>/dev/null || true
        restored_peers=$(ls -1 "$PEERS_DIR"/*.conf 2>/dev/null | wc -l)
    fi

    if [ -d "$inner/suspended" ] && [ "$(ls -A "$inner/suspended" 2>/dev/null)" ]; then
        rm -f "$SUSPENDED_DIR"/*.conf
        cp "$inner/suspended"/*.conf "$SUSPENDED_DIR/" 2>/dev/null || true
        chmod 600 "$SUSPENDED_DIR"/*.conf 2>/dev/null || true
        restored_suspended=$(ls -1 "$SUSPENDED_DIR"/*.conf 2>/dev/null | wc -l)
    fi

    if [ -d "$inner/clients" ] && [ "$(ls -A "$inner/clients" 2>/dev/null)" ]; then
        rm -f "$CLIENTS_DIR"/*.conf
        cp "$inner/clients"/*.conf "$CLIENTS_DIR/" 2>/dev/null || true
        chmod 600 "$CLIENTS_DIR"/*.conf 2>/dev/null || true
        restored_clients=$(ls -1 "$CLIENTS_DIR"/*.conf 2>/dev/null | wc -l)
    fi

    # Restore DB
    if [ -f "$inner/wg-manage.db" ]; then
        cp "$inner/wg-manage.db" "$DB_FILE"
        chmod 600 "$DB_FILE"
    fi

    # Restore wg0.conf (interface only)
    if [ -f "$inner/wg0.conf" ]; then
        cp "$inner/wg0.conf" "$WG_CONF"
        chmod 600 "$WG_CONF"
    fi

    rm -rf "$tmpdir"

    # Sync live WireGuard
    sync_wg

    audit "restore" "" "" ""
    git_autocommit "restore" "" "from=$bak_name peers=$restored_peers suspended=$restored_suspended clients=$restored_clients"

    ok "restored from $bak_name — $restored_peers peers (${restored_suspended} suspended, $restored_clients clients) (version: ${WG_LAST_VERSION:-?})"
}

# ── Single-peer restore helper ──
restore_single_peer() {
    local inner="$1" peer_name="$2" bak_name="$3"
    local esc_peer peer_found=false peer_status="active"

    esc_peer=$(db_escape "$peer_name")

    # Restore peer config (check both peers/ and suspended/)
    if [ -f "$inner/peers/${peer_name}.conf" ]; then
        cp "$inner/peers/${peer_name}.conf" "$PEERS_DIR/${peer_name}.conf"
        chmod 600 "$PEERS_DIR/${peer_name}.conf"
        rm -f "$SUSPENDED_DIR/${peer_name}.conf"
        peer_status="active"
        peer_found=true
    elif [ -f "$inner/suspended/${peer_name}.conf" ]; then
        cp "$inner/suspended/${peer_name}.conf" "$SUSPENDED_DIR/${peer_name}.conf"
        chmod 600 "$SUSPENDED_DIR/${peer_name}.conf"
        rm -f "$PEERS_DIR/${peer_name}.conf"
        peer_status="suspended"
        peer_found=true
    fi

    $peer_found || die "peer '$peer_name' not found in backup"

    # Restore client config
    if [ -f "$inner/clients/${peer_name}.conf" ]; then
        cp "$inner/clients/${peer_name}.conf" "$CLIENTS_DIR/${peer_name}.conf"
        chmod 600 "$CLIENTS_DIR/${peer_name}.conf"
    else
        rm -f "$CLIENTS_DIR/${peer_name}.conf"
    fi

    # Restore DB row from backup DB
    if [ -f "$inner/wg-manage.db" ]; then
        local bak_db="$inner/wg-manage.db"

        # Read peer data from backup DB
        local peer_data peer_id bak_ip bak_hub
        peer_data=$(sqlite3 "$bak_db" "SELECT public_key,private_key,preshared_key,allowed_ips,hub,endpoint,dns,description FROM peers WHERE name='$esc_peer';" 2>/dev/null || echo "")
        if [ -n "$peer_data" ]; then
            IFS='|' read -r bak_pub bak_priv bak_psk bak_ip bak_hub bak_ep bak_dns bak_desc <<< "$peer_data"

            local esc_pub esc_priv esc_psk esc_ip esc_hub esc_ep esc_dns esc_desc
            esc_pub=$(db_escape "$bak_pub")
            esc_priv=$(db_escape "$bak_priv")
            esc_psk=$(db_escape "$bak_psk")
            esc_ip=$(db_escape "$bak_ip")
            esc_hub=$(db_escape "$bak_hub")
            esc_ep=$(db_escape "$bak_ep")
            esc_dns=$(db_escape "${bak_dns:-1.1.1.1,8.8.8.8}")
            esc_desc=$(db_escape "$bak_desc")

            # Delete old peer row if exists, then insert
            db_query "DELETE FROM peers WHERE name='$esc_peer';"
            db_query "DELETE FROM ip_pool WHERE peer_id IN (SELECT id FROM peers WHERE name='$esc_peer');" 2>/dev/null || true

            db_query "INSERT INTO peers (name,public_key,private_key,preshared_key,allowed_ips,hub,region,status,endpoint,dns,description) VALUES ('$esc_peer','$esc_pub','$esc_priv','$esc_psk','$esc_ip','$esc_hub',0,'$peer_status','$esc_ep','$esc_dns','$esc_desc');"

            # Restore ip_pool entry from backup DB
            peer_id=$(db_query "SELECT id FROM peers WHERE name='$esc_peer';")
            local pool_data
            pool_data=$(sqlite3 "$bak_db" "SELECT subnet_a,subnet_b,octet_c,octet_d FROM ip_pool WHERE peer_id=(SELECT id FROM peers WHERE name='$esc_peer');" 2>/dev/null || echo "")
            if [ -n "$pool_data" ]; then
                IFS='|' read -r pa pb pc pd <<< "$pool_data"
                [ -n "$pa" ] && db_query "INSERT INTO ip_pool (subnet_a,subnet_b,octet_c,octet_d,peer_id) VALUES ('$pa','$pb',$pc,$pd,$peer_id);" 2>/dev/null || true
            fi
        else
            warn "peer '$peer_name' DB entry not found in backup (config files only restored)"
        fi
    else
        warn "backup DB not found in archive (config files only restored)"
    fi

    # Sync if active
    if [ "$peer_status" = "active" ]; then
        sync_wg
    fi

    local ip_now hub_now
    ip_now=$(db_query "SELECT allowed_ips FROM peers WHERE name='$esc_peer';" 2>/dev/null || echo "?")
    hub_now=$(db_query "SELECT hub FROM peers WHERE name='$esc_peer';" 2>/dev/null || echo "?")
    audit "restore-peer" "$peer_name" "$ip_now" "$hub_now"
    git_autocommit "restore" "$peer_name" "from=$bak_name ip=$ip_now hub=$hub_now status=$peer_status"

    ok "peer '$peer_name' restored from $bak_name (status: $peer_status, ip: $ip_now)"
}

# ============================================================
# COMMAND: migrate
# ============================================================
cmd_migrate() {
    check_root
    [ -f "$WG_CONF" ] || die "wg0.conf not found"

    local old_conf="${WG_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$WG_CONF" "$old_conf"
    info "old config backed up to $old_conf"

    mkdir -p "$PEERS_DIR" "$SUSPENDED_DIR" "$CLIENTS_DIR"
    init_db

    local interface_end_line=0
    local interface_lines=""
    local current_name="" current_block="" skip_peer=false removed_count=0 kept_count=0
    local peer_names=()

    # Parse old config
    while IFS= read -r line || [ -n "$line" ]; do
        # Detect end of [Interface] section
        if [[ "$line" =~ ^\[Peer\]$ ]]; then
            # Save current block if any and process
            if [ -n "$current_name" ] && [ -n "$current_block" ]; then
                if $skip_peer; then
                    removed_count=$((removed_count + 1))
                    info "  REMOVED: $current_name (region 1 or 2 — US/EU)"
                else
                    # Write peer config file
                    {
                        echo "# $current_name"
                        echo "[Peer]"
                        echo "$current_block"
                    } > "$PEERS_DIR/${current_name}.conf"
                    chmod 600 "$PEERS_DIR/${current_name}.conf"
                    peer_names+=("$current_name")
                    kept_count=$((kept_count + 1))
                fi
                current_name=""; current_block=""; skip_peer=false
            fi
            # Start new peer block
            current_block=""
            continue
        fi

        # Check if we're in Interface section
        if [ "$interface_end_line" -eq 0 ]; then
            if [[ "$line" =~ ^\[Interface\]$ ]]; then
                interface_lines="$line"
            elif [[ "$line" =~ ^\[Peer\]$ ]]; then
                interface_end_line=1
                current_block=""
                continue
            elif [[ "$line" =~ ^PostUp ]] || [[ "$line" =~ ^PostDown ]] || [[ "$line" =~ ^PrivateKey ]] || [[ "$line" =~ ^Address ]] || [[ "$line" =~ ^ListenPort ]]; then
                interface_lines="$interface_lines"$'\n'"$line"
            elif [ -z "$line" ] && [ -z "$interface_lines" ]; then
                continue
            elif [[ -n "$line" ]]; then
                interface_lines="$interface_lines"$'\n'"$line"
            fi
            if [[ -z "$line" ]]; then
                interface_end_line=1
            fi
            continue
        fi

        # In peer section
        if [[ "$line" =~ ^#[[:space:]]*User:[[:space:]]*(.+) ]]; then
            current_name="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^#[[:space:]]*(.+) ]] && [[ -z "$current_name" ]]; then
            current_name="${BASH_REMATCH[1]}"
        fi

        # Track for region detection
        if [[ "$line" =~ ^AllowedIPs[[:space:]]*=[[:space:]]*([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
            local ip_region="${BASH_REMATCH[3]}"
            if [ "$ip_region" -eq 1 ] || [ "$ip_region" -eq 2 ]; then
                skip_peer=true
            fi
        fi

        [ -n "$line" ] && current_block="$current_block"$'\n'"$line"
    done < "$old_conf"

    # Process last peer
    if [ -n "$current_name" ] && [ -n "$current_block" ]; then
        if $skip_peer; then
            removed_count=$((removed_count + 1))
            info "  REMOVED: $current_name (region 1 or 2 — US/EU)"
        else
            {
                echo "# $current_name"
                echo "[Peer]"
                echo "$current_block"
            } > "$PEERS_DIR/${current_name}.conf"
            chmod 600 "$PEERS_DIR/${current_name}.conf"
            peer_names+=("$current_name")
            kept_count=$((kept_count + 1))
        fi
    fi

    # Write new wg0.conf (interface only)
    {
        echo "$interface_lines"
        echo ""
        echo "# ── Peer configs managed by wg-manage ──"
        echo "# Active peers: /etc/wireguard/peers/*.conf"
        echo "# Suspended:    /etc/wireguard/suspended/*.conf"
        echo "# DO NOT add peers here manually."
    } > "$WG_CONF"
    chmod 600 "$WG_CONF"

    # Register peers in DB
    for name in "${peer_names[@]}"; do
        local conf="$PEERS_DIR/${name}.conf"
        local pubkey allowed_ip region hub
        pubkey=$(grep -oP '^PublicKey\s*=\s*\K.+' "$conf" 2>/dev/null || echo "")
        allowed_ip=$(grep -oP '^AllowedIPs\s*=\s*\K.+' "$conf" 2>/dev/null || echo "")
        region=$(ip_to_region "${allowed_ip%/32}")
        hub=$(hub_for_region "$region")
        local endpoint
        endpoint=$(grep -oP '^Endpoint\s*=\s*\K.+' "$conf" 2>/dev/null || echo "")
        local octet
        octet=$(echo "${allowed_ip%/32}" | cut -d. -f4)

        local esc_name esc_pub esc_ip esc_hub esc_ep
        esc_name=$(db_escape "$name")
        esc_pub=$(db_escape "$pubkey")
        esc_ip=$(db_escape "$allowed_ip")
        esc_hub=$(db_escape "$hub")
        esc_ep=$(db_escape "$endpoint")

        db_query "INSERT INTO peers (name,public_key,private_key,allowed_ips,hub,region,status,endpoint) VALUES ('$esc_name','$esc_pub','','$esc_ip','$esc_hub',$region,'active','$esc_ep');"
        local peer_id
        peer_id=$(db_query "SELECT id FROM peers WHERE name='$esc_name';")
        db_query "INSERT INTO ip_pool (region,octet,peer_id) VALUES ($region,$octet,$peer_id);"
    done

    info "migration complete: $kept_count kept, $removed_count removed (US/EU regions)"
    ok "running sync to apply..."

    sync_wg

    # Git
    cd "$GIT_DIR" || true
    if git rev-parse --git-dir &>/dev/null; then
        echo "0.00.01" > "$VERSION_FILE"
    git add peers/ suspended/ clients/ wg0.conf .version &>/dev/null || true
        git commit -m "migrate: initial peer migration — $kept_count peers kept, $removed_count removed (US/EU)" --quiet 2>/dev/null || true
        local short_hash
        short_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "0000000")
        git tag "v0.00.01-${short_hash}" 2>/dev/null || true
        ok "git commit: v0.00.01-${short_hash}"
    fi

    ok "migration finished successfully"
    echo ""
    echo -e "${C_BOLD}Next:${C_RESET} run 'wg-manage list' to verify"
}

# ============================================================
# COMMAND: help
# ============================================================
cmd_help() {
    echo -e "${C_BOLD}wg-manage${C_RESET} — WireGuard Peer Management"
    echo ""
    echo "Usage: wg-manage <command> [args...]"
    echo ""
    echo -e "${C_BOLD}Peer Management:${C_RESET}"
    echo "  add <name> [--hub mn|sgp] [--ip <addr>] [--allowed-ips <cidr>] [--dns <ip>] [--desc <text>] [--psk]"
    echo "  remove <name> [--force]"
    echo "  suspend <name>"
    echo "  unsuspend <name>"
    echo "  rename <old-name> <new-name> [--force]"
    echo "  ip <name> <new-ip> [--force]"
    echo ""
    echo -e "${C_BOLD}View:${C_RESET}"
    echo "  list [active|suspended|all] [<search>] [--hub <h>]"
    echo "  show <name> [--show-key]"
    echo "  qr <name> [--size 10]"
    echo "  info"
    echo ""
    echo -e "${C_BOLD}System:${C_RESET}"
    echo "  sync [--no-commit]"
    echo "  backup"
    echo "  restore <backup-file> [--force] [--peer <name>] | restore --latest [--force] [--peer <name>]"
    echo ""
    echo -e "${C_BOLD}Examples:${C_RESET}"
    echo "  wg-manage add dev01                                     # auto IP, MN hub (10.232.x.x)"
    echo "  wg-manage add dev02 --ip 10.232.0.77                    # custom IP (MN subnet)"
    echo "  wg-manage add sgp-peer --hub sgp                        # SGP hub (10.233.x.x)"
    echo "  wg-manage add sgp-peer --hub sgp --ip 10.233.0.50       # SGP hub, custom IP"
    echo "  wg-manage add vpn --allowed-ips 10.0.0.1/32,10.233.0.0/16"
    echo "  wg-manage list                                          # all peers"
    echo "  wg-manage list active --hub mn                          # active MN peers"
    echo "  wg-manage list gpu                                      # search by name"
    echo "  wg-manage show dev01                                    # peer details + client config"
    echo "  wg-manage qr dev01                                      # show QR code"
    echo "  wg-manage suspend dev01                                 # suspend a peer"
    echo "  wg-manage remove dev01 --force                          # force remove"
    echo "  wg-manage rename pbs4-95 dc04-pbs4 --force              # rename peer"
    echo "  wg-manage ip dc04-pbs4 10.232.7.100 --force             # change peer IP (hub auto-detected)"
    echo "  wg-manage restore --latest --force                      # restore from latest backup"
    echo "  wg-manage restore --latest --peer dev01 --force         # restore single peer from backup"
}

# ============================================================
# MAIN
# ============================================================
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        add)        cmd_add "$@" ;;
        remove|rm)  cmd_remove "$@" ;;
        suspend)    cmd_suspend "$@" ;;
        unsuspend)  cmd_unsuspend "$@" ;;
        rename)     cmd_rename "$@" ;;
        ip)         cmd_ip "$@" ;;
        list|ls)    cmd_list "$@" ;;
        show)       cmd_show "$@" ;;
        qr)         cmd_qr "$@" ;;
        sync)       cmd_sync "$@" ;;
        info)       cmd_info "$@" ;;
        backup)     cmd_backup "$@" ;;
        restore)    cmd_restore "$@" ;;
        migrate)    cmd_migrate "$@" ;;
        help|--help|-h) cmd_help ;;
        *)          echo "Unknown command: $cmd"; cmd_help; exit 1 ;;
    esac
}

main "$@"
