#!/usr/bin/env bash
set -euo pipefail

APP="TorrServer (Alpine LXC)"
DEF_TAGS="alpine;community-script;torrent;streaming"

# Defaults
DEF_HOSTNAME="torrserver"
DEF_ROOTFS_SIZE="1"       # GiB
DEF_DATA_SIZE="4"         # GiB (/opt/ts)
DEF_RAM="256"             # MiB
DEF_CORES="1"
DEF_BRIDGE="vmbr0"
DEF_IPCONF="dhcp"
DEF_TZ="Europe/Moscow"
DEF_PORT="80"
FALLBACK_TEMPLATE="alpine-3.22-default_20250617_amd64.tar.xz"

# ---------- Pretty output (ASCII only) ----------
CLR="\e[0m"; BL="\e[36m"; GN="\e[32m"; YW="\e[33m"; RD="\e[31m"
log()  { echo -e "${BL}==>${CLR} $*" >&2; }
ok()   { echo -e "${GN}[OK]${CLR} $*" >&2; }
warn() { echo -e "${YW}[!!]${CLR} $*" >&2; }
die()  { echo -e "${RD}[ERR]${CLR} $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
have_whiptail() { command -v whiptail >/dev/null 2>&1; }

ensure_whiptail() {
  if have_whiptail; then return 0; fi
  warn "whiptail not found on host; trying to install..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y whiptail >/dev/null 2>&1 || true
  fi
  have_whiptail || warn "whiptail still missing; falling back to text prompts."
}

ask() {
  local title="$1" prompt="$2" def="$3" out
  if have_whiptail; then
    out=$(whiptail --backtitle "Proxmox VE Helper-Scripts style" --title "$title" \
      --inputbox "$prompt" 9 78 "$def" 3>&1 1>&2 2>&3) || exit 1
    echo "$out"
  else
    read -r -p "$prompt [$def]: " out
    echo "${out:-$def}"
  fi
}

menu() {
  local title="$1"; shift
  local prompt="$1"; shift
  local def="$1"; shift
  if have_whiptail; then
    whiptail --backtitle "Proxmox VE Helper-Scripts style" --title "$title" \
      --menu "$prompt" 18 88 12 --default-item "$def" "$@" 3>&1 1>&2 2>&3
  else
    local tags=()
    while [ $# -gt 0 ]; do tags+=("$1"); shift; shift || true; done
    echo "Select: $prompt" >&2
    local i=1; for t in "${tags[@]}"; do echo "  $i) $t" >&2; i=$((i+1)); done
    local n; read -r -p "Choice [1-${#tags[@]}] (default: 1): " n
    n="${n:-1}"; echo "${tags[$((n-1))]}"
  fi
}

password_prompt_optional() {
  if have_whiptail; then
    local pw1 pw2
    while true; do
      pw1=$(whiptail --backtitle "Proxmox VE Helper-Scripts style" \
        --passwordbox "\nRoot password (leave empty to skip)" 10 78 \
        --title "ROOT PASSWORD" 3>&1 1>&2 2>&3) || exit 1
      [ -z "$pw1" ] && { echo ""; return 0; }
      pw2=$(whiptail --backtitle "Proxmox VE Helper-Scripts style" \
        --passwordbox "\nVerify root password" 10 78 \
        --title "VERIFY PASSWORD" 3>&1 1>&2 2>&3) || exit 1
      [ "$pw1" = "$pw2" ] && { echo "$pw1"; return 0; }
      whiptail --msgbox "Passwords do not match. Try again." 8 50
    done
  else
    local pw
    read -r -s -p "Root password (empty = skip): " pw; echo >&2
    echo "$pw"
  fi
}

validate_password_for_chpasswd() {
  local pw="$1"
  if printf "%s" "$pw" | grep -q $'[\n\r:]'; then
    die "Password contains forbidden characters (: or newline). Choose another password."
  fi
}

pick_latest_alpine_template() {
  local arch="$1"
  pveam available --section system \
    | awk '{print $2}' \
    | grep -E "^alpine-[0-9.]+-default_[0-9]+_${arch}\.tar\.xz$" \
    | sort -V \
    | tail -1
}

storages_rows_for_content() {
  local content="$1"
  pvesm status -content "$content" 2>/dev/null | awk 'NR>1'
}

select_storage() {
  local title="$1" content="$2" label="$3"

  mapfile -t rows < <(storages_rows_for_content "$content")
  [ "${#rows[@]}" -gt 0 ] || die "No storage found with content '$content'"

  local opts=()
  local first=""
  command -v numfmt >/dev/null 2>&1 || warn "numfmt missing; sizes shown raw."

  for r in "${rows[@]}"; do
    local name type status total used availp
    name="$(awk '{print $1}' <<<"$r")"
    type="$(awk '{print $2}' <<<"$r")"
    status="$(awk '{print $3}' <<<"$r")"
    total="$(awk '{print $4}' <<<"$r")"
    used="$(awk '{print $5}' <<<"$r")"
    availp="$(awk '{print $6}' <<<"$r")"
    [ "$status" = "active" ] || continue
    [ -z "$first" ] && first="$name"

    local free_k=$((total-used))
    local total_h used_h free_h
    if command -v numfmt >/dev/null 2>&1; then
      total_h="$(numfmt --from-unit=K --to=iec --format='%.1f' "$total" 2>/dev/null || echo "${total}K")"
      used_h="$(numfmt --from-unit=K --to=iec --format='%.1f' "$used" 2>/dev/null || echo "${used}K")"
      free_h="$(numfmt --from-unit=K --to=iec --format='%.1f' "$free_k" 2>/dev/null || echo "${free_k}K")"
    else
      total_h="${total}K"; used_h="${used}K"; free_h="${free_k}K"
    fi
    opts+=("$name" "type=$type free=$free_h used=$used_h total=$total_h ($availp)")
  done

  [ -n "$first" ] || die "No ACTIVE storage found for content '$content'"
  menu "$title" "Select storage for ${label}" "$first" "${opts[@]}"
}

collect_host_ssh_keys() {
  {
    [ -f /root/.ssh/authorized_keys ] && cat /root/.ssh/authorized_keys
    cat /root/.ssh/*.pub 2>/dev/null || true
    [ -f /etc/pve/priv/authorized_keys ] && cat /etc/pve/priv/authorized_keys
  } | awk 'NF>1 && $1 ~ /^ssh-|^ecdsa-|^sk-ssh-/ {print $0}' | awk '!seen[$0]++'
}

ssh_key_mode() {
  menu "SSH KEYS" "How to add SSH keys?" "none" \
    "none"   "Do not add SSH keys" \
    "manual" "Paste SSH public key(s)" \
    "pve"    "Select key(s) from Proxmox node"
}

ssh_keys_manual_multiline() {
  local tf
  tf="$(mktemp)"
  if have_whiptail; then
    whiptail --backtitle "Proxmox VE Helper-Scripts style" \
      --title "SSH KEYS (manual)" \
      --editbox "$tf" 20 88 3>&1 1>&2 2>&3 || true
  else
    warn "No whiptail; paste keys then Ctrl-D."
    cat >"$tf" || true
  fi
  cat "$tf"
  rm -f "$tf"
}

ssh_keys_select_from_pve() {
  local existing
  existing="$(collect_host_ssh_keys || true)"
  [ -n "$existing" ] || { warn "No SSH keys found on Proxmox node."; echo ""; return 0; }

  if ! have_whiptail; then
    warn "No whiptail; using first key from node."
    echo "$existing" | head -n 1
    return 0
  fi

  local opts=()
  local i=1
  while IFS= read -r line; do
    local comment
    comment="$(awk '{print $NF}' <<<"$line")"
    opts+=("$i" "$comment" "OFF")
    i=$((i+1))
  done <<<"$existing"

  local sel=""
  sel=$(whiptail --backtitle "Proxmox VE Helper-Scripts style" \
    --title "SSH KEYS (from Proxmox)" \
    --checklist "Select keys (SPACE to toggle)" \
    20 88 12 "${opts[@]}" 3>&1 1>&2 2>&3) || true

  [ -n "$sel" ] || { echo ""; return 0; }

  local picked=""
  local idx
  for idx in $sel; do
    idx="${idx//\"/}"
    picked+=$(echo "$existing" | sed -n "${idx}p")
    picked+=$'\n'
  done

  echo "$picked" | awk 'NF>1 && $1 ~ /^ssh-|^ecdsa-|^sk-ssh-/ {print $0}' | awk '!seen[$0]++'
}

main() {
  [ "$(id -u)" -eq 0 ] || die "Run as root on Proxmox node."

  need_cmd pct
  need_cmd pveam
  need_cmd pvesh
  need_cmd pvesm
  need_cmd dpkg
  need_cmd awk
  need_cmd grep
  need_cmd sort
  need_cmd tail
  ensure_whiptail

  local CTID
  CTID="$(pvesh get /cluster/nextid)"

  local MODE
  MODE="$(menu "SETTINGS" "Choose settings mode" "default" \
    "default"  "Default Settings" \
    "advanced" "Advanced Settings")"

  log "Auto Container ID: $CTID"
  log "Select storages..."
  local TEMPLATE_STORAGE ROOTFS_STORAGE DATA_STORAGE
  TEMPLATE_STORAGE="$(select_storage "TEMPLATE STORAGE" "vztmpl" "LXC templates (vztmpl)")"
  ROOTFS_STORAGE="$(select_storage "ROOTFS STORAGE" "rootdir" "container rootfs (rootdir)")"
  DATA_STORAGE="$(select_storage "DATA STORAGE" "rootdir" "data volume for /opt/ts (rootdir)")"

  local HOSTNAME ROOTFS_SIZE DATA_SIZE RAM CORES BRIDGE IPCONF TZ PORT TAGS
  if [ "$MODE" = "advanced" ]; then
    HOSTNAME="$(ask "HOSTNAME" "Container hostname" "$DEF_HOSTNAME")"
    ROOTFS_SIZE="$(ask "ROOTFS SIZE" "RootFS size (GiB)" "$DEF_ROOTFS_SIZE")"
    DATA_SIZE="$(ask "DATA SIZE" "/opt/ts volume size (GiB)" "$DEF_DATA_SIZE")"
    RAM="$(ask "RAM" "RAM (MiB)" "$DEF_RAM")"
    CORES="$(ask "CORES" "CPU cores" "$DEF_CORES")"
    BRIDGE="$(ask "NETWORK" "Bridge (e.g. vmbr0)" "$DEF_BRIDGE")"
    IPCONF="$(ask "NETWORK" "IPv4 (dhcp OR ip/mask,gw=gwip)" "$DEF_IPCONF")"
    TZ="$(ask "TIMEZONE" "Timezone" "$DEF_TZ")"
    PORT="$(ask "PORT" "TorrServer port (80 supported via supervise-daemon capabilities)" "$DEF_PORT")"
    TAGS="$(ask "TAGS" "Container tags (semicolon-separated)" "$DEF_TAGS")"
  else
    HOSTNAME="$DEF_HOSTNAME"
    ROOTFS_SIZE="$DEF_ROOTFS_SIZE"
    DATA_SIZE="$DEF_DATA_SIZE"
    RAM="$DEF_RAM"
    CORES="$DEF_CORES"
    BRIDGE="$DEF_BRIDGE"
    IPCONF="$DEF_IPCONF"
    TZ="$DEF_TZ"
    PORT="$DEF_PORT"
    TAGS="$DEF_TAGS"
  fi

  case "$PORT" in
    ''|*[!0-9]*) die "PORT must be numeric, got: '$PORT'" ;;
  esac

  log "Auth: you can set BOTH root password and SSH keys."
  local ROOT_PW
  ROOT_PW="$(password_prompt_optional)"
  if [ -n "${ROOT_PW:-}" ]; then validate_password_for_chpasswd "$ROOT_PW"; fi

  local SSH_MODE SSH_KEYS SSH_KEYS_FILE=""
  SSH_MODE="$(ssh_key_mode)"
  case "$SSH_MODE" in
    none)   SSH_KEYS="";;
    manual) SSH_KEYS="$(ssh_keys_manual_multiline)";;
    pve)    SSH_KEYS="$(ssh_keys_select_from_pve)";;
    *)      SSH_KEYS="";;
  esac
  SSH_KEYS="$(echo "${SSH_KEYS:-}" | awk 'NF>0')"

  if [ -n "${SSH_KEYS:-}" ]; then
    SSH_KEYS_FILE="$(mktemp)"
    printf "%s\n" "$SSH_KEYS" >"$SSH_KEYS_FILE"
    ok "SSH keys prepared: $(wc -l <"$SSH_KEYS_FILE")"
  else
    ok "SSH keys: none"
  fi

  log "Selecting Alpine template..."
  pveam update >/dev/null 2>&1 || true

  local host_arch tpl_arch
  host_arch="$(dpkg --print-architecture)"
  case "$host_arch" in
    amd64) tpl_arch="amd64" ;;
    arm64) tpl_arch="arm64" ;;
    *) die "Unsupported PVE arch: $host_arch" ;;
  esac

  local TEMPLATE
  TEMPLATE="$(pick_latest_alpine_template "$tpl_arch" || true)"
  [ -n "${TEMPLATE:-}" ] || TEMPLATE="$FALLBACK_TEMPLATE"

  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null 2>&1 || true
  ok "Template ready: $TEMPLATE (storage: $TEMPLATE_STORAGE)"

  log "Creating LXC..."
  local -a PCT_ARGS
  PCT_ARGS=(
    create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"
    --ostype alpine
    --hostname "$HOSTNAME"
    --cores "$CORES" --memory "$RAM" --swap 128
    --rootfs "${ROOTFS_STORAGE}:${ROOTFS_SIZE}"
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IPCONF}"
    --unprivileged 1
    --onboot 1
    --timezone "$TZ"
    --tags "$TAGS"
    --mp0 "${DATA_STORAGE}:${DATA_SIZE},mp=/opt/ts"
    --start 1
  )

  # pct create supports these options. [page:1]
  [ -n "${ROOT_PW:-}" ] && PCT_ARGS+=( --password "$ROOT_PW" )
  [ -n "${SSH_KEYS_FILE:-}" ] && PCT_ARGS+=( --ssh-public-keys "$SSH_KEYS_FILE" )

  pct "${PCT_ARGS[@]}"
  ok "LXC created and started"

  # Prepare auth payloads for inside-CT enforcement
  local ROOTPW_FILE=""
  if [ -n "${ROOT_PW:-}" ]; then
    ROOTPW_FILE="$(mktemp)"
    printf "root:%s\n" "$ROOT_PW" >"$ROOTPW_FILE"
  fi

  log "Provisioning inside container..."
  cat > /tmp/provision-torrserver-alpine.sh <<'EOF'
#!/bin/sh
set -eu

: "${TZ:=Europe/Moscow}"
: "${PORT:=80}"
: "${ENABLE_SSH:=0}"      # 1/0
: "${ROOTPW_FILE:=}"      # optional path with "root:pass"
: "${SSHKEYS_FILE:=}"     # optional path with public keys (one per line)

case "${PORT}" in
  ''|*[!0-9]*) echo "Invalid PORT=${PORT}" >&2; exit 1 ;;
esac

apk add --no-cache ca-certificates curl wget tzdata bash gcompat libc6-compat openssh ffmpeg

# timezone
if [ -e "/usr/share/zoneinfo/${TZ}" ]; then
  cp "/usr/share/zoneinfo/${TZ}" /etc/localtime
  echo "${TZ}" > /etc/timezone
fi

# root password
if [ -n "${ROOTPW_FILE}" ] && [ -f "${ROOTPW_FILE}" ]; then
  chpasswd < "${ROOTPW_FILE}" || true
  passwd -u root 2>/dev/null || true
fi

# ssh keys
if [ -n "${SSHKEYS_FILE}" ] && [ -f "${SSHKEYS_FILE}" ]; then
  mkdir -p /root/.ssh
  cat "${SSHKEYS_FILE}" >> /root/.ssh/authorized_keys
  chmod 700 /root/.ssh
  chmod 600 /root/.ssh/authorized_keys
fi

# enable ssh if requested
if [ "${ENABLE_SSH}" = "1" ]; then
  ssh-keygen -A
  if [ -n "${ROOTPW_FILE}" ] && [ -f "${ROOTPW_FILE}" ]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config || true
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
  else
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config || true
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config || true
  fi
  rc-update add sshd default
  rc-service sshd restart || rc-service sshd start
fi

# /opt/ts volume + home
mkdir -p /opt/ts/config /opt/ts/cache /opt/ts/log /opt/ts/home
ln -snf /opt/ts/cache /opt/ts/torrents

addgroup -S torrserver 2>/dev/null || true

# Create user with home at /opt/ts/home (no-login)
# NOTE: adduser flags differ across distros; in Alpine BusyBox adduser supports -h for home.
adduser -S -D -H -h /opt/ts/home -s /sbin/nologin -G torrserver torrserver 2>/dev/null || true

chown -R torrserver:torrserver /opt/ts || true

# download TorrServer
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  TSARCH="amd64" ;;
  aarch64) TSARCH="arm64" ;;
  armv7*|armv7l) TSARCH="arm7" ;;
  armv6*|armv6l) TSARCH="arm5" ;;
  i386|i686) TSARCH="386" ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

BIN="/usr/local/bin/torrserver"
URL="https://github.com/YouROK/TorrServer/releases/latest/download/TorrServer-linux-${TSARCH}"
curl -L -o "${BIN}" "${URL}"
chmod +x "${BIN}"

# config
cat > /etc/conf.d/torrserver <<CONF
TZ=${TZ}
TS_PORT=${PORT}
TS_DONTKILL=1
TS_CONF_PATH=/opt/ts/config
TS_TORR_DIR=/opt/ts/cache
TS_LOG_PATH=/opt/ts/log/torrserver.log
TS_HOME=/opt/ts/home
CONF

# wrapper with logging + HOME
cat > /usr/local/bin/torrserver-run <<'RUN'
#!/usr/bin/env bash
set -euo pipefail
set -a
[ -f /etc/conf.d/torrserver ] && . /etc/conf.d/torrserver
set +a

export HOME="${TS_HOME:-/opt/ts/home}"

mkdir -p /opt/ts/log || true
exec >>/opt/ts/log/torrserver.stdout.log 2>>/opt/ts/log/torrserver.stderr.log

ARGS=( "--port" "${TS_PORT:-80}"
       "--path" "${TS_CONF_PATH:-/opt/ts/config}"
       "--torrentsdir" "${TS_TORR_DIR:-/opt/ts/cache}" )

[ "${TS_DONTKILL:-0}" = "1" ] && ARGS+=( "--dontkill" )
[ "${TS_HTTPAUTH:-0}" = "1" ] && ARGS+=( "--httpauth" )
[ "${TS_RDB:-0}" = "1" ] && ARGS+=( "--rdb" )

if [ -n "${TS_LOG_PATH:-}" ]; then
  mkdir -p "$(dirname "${TS_LOG_PATH}")"
  ARGS+=( "--logpath" "${TS_LOG_PATH}" )
fi

echo "Starting TorrServer at $(date -Iseconds) with HOME=${HOME} args: ${ARGS[*]}" >&2
exec /usr/local/bin/torrserver "${ARGS[@]}"
RUN
chmod +x /usr/local/bin/torrserver-run

# OpenRC service: use supervise-daemon with capabilities so bind(80) works in unprivileged LXC
# supervise-daemon supports --capabilities cap-list. [page:0]
cat > /etc/init.d/torrserver <<'INIT'
#!/sbin/openrc-run
name="torrserver"
description="TorrServer"
command="/usr/local/bin/torrserver-run"
command_user="torrserver:torrserver"

supervisor="supervise-daemon"
pidfile="/run/${RC_SVCNAME}.pid"

respawn_delay=5
respawn_max=0
respawn_period=0

# CAP_NET_BIND_SERVICE allows binding to ports <1024 (like 80) without running as root.
# Using supervise-daemon --capabilities is more reliable than filecap in some container setups.
supervise_daemon_args="--capabilities cap_net_bind_service+eip"

depend() { need net; }
INIT
chmod +x /etc/init.d/torrserver

rc-update add torrserver default
rc-service torrserver restart || rc-service torrserver start
EOF

  chmod +x /tmp/provision-torrserver-alpine.sh
  pct push "$CTID" /tmp/provision-torrserver-alpine.sh /root/provision-torrserver.sh

  # push optional auth files
  local ENABLE_SSH=0
  if [ -n "${ROOTPW_FILE:-}" ]; then
    pct push "$CTID" "$ROOTPW_FILE" /root/.rootpw --perms 0600
    ENABLE_SSH=1
  fi
  if [ -n "${SSH_KEYS_FILE:-}" ]; then
    pct push "$CTID" "$SSH_KEYS_FILE" /root/.sshkeys --perms 0600
    ENABLE_SSH=1
  fi

  pct exec "$CTID" -- env \
    TZ="$TZ" PORT="$PORT" \
    ENABLE_SSH="$ENABLE_SSH" \
    ROOTPW_FILE="/root/.rootpw" \
    SSHKEYS_FILE="/root/.sshkeys" \
    sh /root/provision-torrserver.sh

  ok "Provision complete"

  # cleanup host temp files
  [ -n "${SSH_KEYS_FILE:-}" ] && rm -f "$SSH_KEYS_FILE" || true
  [ -n "${ROOTPW_FILE:-}" ] && rm -f "$ROOTPW_FILE" || true

  echo >&2
  ok "Created CTID: $CTID"
  ok "Tags: $TAGS"
  ok "TorrServer URL: http://<CT_IP>:${PORT}"
  ok "Service check: pct exec ${CTID} -- rc-service torrserver status"
  ok "Port check: pct exec ${CTID} -- sh -lc 'apk add --no-cache iproute2-ss >/dev/null 2>&1 || true; ss -ltnp \"( sport = :${PORT} )\" || true'"
  ok "Logs: pct exec ${CTID} -- tail -n 120 /opt/ts/log/torrserver.stderr.log"
}

main "$@"
