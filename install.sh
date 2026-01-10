#!/usr/bin/env bash
set -euo pipefail

APP="TorrServer (Alpine LXC)"
DEF_TAGS="alpine;community-script;torrent;streaming"

# Defaults (Default mode uses these; Advanced mode uses as pre-filled values)
DEF_HOSTNAME="torrserver"
DEF_ROOTFS_SIZE="1"      # GiB
DEF_DATA_SIZE="4"        # GiB (for /opt/ts)
DEF_RAM="256"            # MiB
DEF_CORES="1"
DEF_BRIDGE="vmbr0"
DEF_IPCONF="dhcp"        # or: 192.168.1.50/24,gw=192.168.1.1
DEF_TZ="Europe/Moscow"
DEF_PORT="8090"
FALLBACK_TEMPLATE="alpine-3.22-default_20250617_amd64.tar.xz"

# ---------- Pretty output ----------
BOLD="\e[1m"; CLR="\e[0m"
GN="\e[32m"; YW="\e[33m"; RD="\e[31m"; BL="\e[36m"

msg()  { echo -e "${BL}==>${CLR} $*"; }
ok()   { echo -e "${GN}✓${CLR} $*"; }
warn() { echo -e "${YW}!${CLR} $*"; }
die()  { echo -e "${RD}✗${CLR} $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
have_whiptail() { command -v whiptail >/dev/null 2>&1; }

# ---------- UI helpers ----------
ensure_whiptail() {
  if have_whiptail; then return 0; fi
  warn "whiptail not found on host; trying to install for nicer UI..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y whiptail >/dev/null 2>&1 || true
  fi
  if ! have_whiptail; then
    warn "whiptail still missing; falling back to text prompts."
  fi
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
  # menu "TITLE" "PROMPT" "DEFAULT" tag1 item1 tag2 item2 ...
  local title="$1"; shift
  local prompt="$1"; shift
  local def="$1"; shift

  if have_whiptail; then
    whiptail --backtitle "Proxmox VE Helper-Scripts style" --title "$title" \
      --menu "$prompt" 18 86 12 --default-item "$def" "$@" 3>&1 1>&2 2>&3
  else
    local tags=()
    while [ $# -gt 0 ]; do tags+=("$1"); shift; shift || true; done
    echo "Select: $prompt"
    local i=1; for t in "${tags[@]}"; do echo "  $i) $t"; i=$((i+1)); done
    local n; read -r -p "Choice [1-${#tags[@]}] (default: 1): " n
    n="${n:-1}"; echo "${tags[$((n-1))]}"
  fi
}

yesno() {
  local title="$1" prompt="$2" default_yes="$3"
  if have_whiptail; then
    if [ "$default_yes" = "1" ]; then
      whiptail --backtitle "Proxmox VE Helper-Scripts style" --title "$title" --yesno "$prompt" 9 78
    else
      whiptail --backtitle "Proxmox VE Helper-Scripts style" --title "$title" --yesno "$prompt" 9 78 --defaultno
    fi
    return $?
  else
    local ans defchar
    defchar="$( [ "$default_yes" = "1" ] && echo y || echo n )"
    read -r -p "$prompt (y/n) [$defchar]: " ans
    ans="${ans:-$defchar}"
    [[ "$ans" =~ ^[Yy]$ ]]
  fi
}

password_prompt_optional() {
  # Outputs password to stdout (may be empty)
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
    read -r -s -p "Root password (empty = skip): " pw; echo
    echo "$pw"
  fi
}

# ---------- Proxmox helpers ----------
pick_latest_alpine_template() {
  local arch="$1" # amd64/arm64
  pveam available --section system \
    | awk '{print $2}' \
    | grep -E "^alpine-[0-9.]+-default_[0-9]+_${arch}\.tar\.xz$" \
    | sort -V \
    | tail -1
}

storages_for_content_rows() {
  local content="$1"
  # columns: name type status total used avail%
  pvesm status -content "$content" 2>/dev/null | awk 'NR>1'
}

select_storage() {
  # select_storage "TITLE" content label
  local title="$1" content="$2" label="$3"

  mapfile -t rows < <(storages_for_content_rows "$content")
  [ "${#rows[@]}" -gt 0 ] || die "No storage found with content '$content'"

  # if only one active -> auto
  local active_count=0
  local last_active=""
  for r in "${rows[@]}"; do
    local st status
    st="$(awk '{print $1}' <<<"$r")"
    status="$(awk '{print $3}' <<<"$r")"
    if [ "$status" = "active" ]; then
      active_count=$((active_count+1))
      last_active="$st"
    fi
  done
  [ "$active_count" -gt 0 ] || die "No ACTIVE storage found with content '$content'"

  if [ "$active_count" -eq 1 ]; then
    ok "Storage for ${label}: ${last_active} (only active option)"
    echo "$last_active"
    return 0
  fi

  # menu options: tag=storage, item=desc
  command -v numfmt >/dev/null 2>&1 || warn "numfmt missing; sizes will be shown raw."

  local opts=()
  local first=""
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

  menu "$title" "Select storage for ${label}" "$first" "${opts[@]}"
}

collect_host_ssh_keys() {
  # Gather keys from common places on Proxmox node; dedup.
  {
    [ -f /root/.ssh/authorized_keys ] && cat /root/.ssh/authorized_keys
    cat /root/.ssh/*.pub 2>/dev/null || true
    [ -f /etc/pve/priv/authorized_keys ] && cat /etc/pve/priv/authorized_keys
  } | awk 'NF>1 && $1 ~ /^ssh-|^ecdsa-|^sk-ssh-/ {print $0}' | awk '!seen[$0]++'
}

select_ssh_keys_optional() {
  # Output selected keys (can be empty)
  local existing manual picked
  existing="$(collect_host_ssh_keys || true)"
  manual=""
  picked=""

  if have_whiptail; then
    manual=$(whiptail --backtitle "Proxmox VE Helper-Scripts style" \
      --title "SSH KEYS (manual input)" \
      --inputbox "Paste public key(s) (optional). Multiple lines allowed.\nLeave empty to skip." \
      14 86 "" 3>&1 1>&2 2>&3) || exit 1
  else
    read -r -p "Paste SSH public key (optional, single line). Empty to skip: " manual
  fi

  if [ -n "$existing" ] && have_whiptail; then
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
      --checklist "Select keys to add (SPACE to toggle)" \
      20 86 12 "${opts[@]}" 3>&1 1>&2 2>&3) || true

    if [ -n "$sel" ]; then
      local idx
      for idx in $sel; do
        idx="${idx//\"/}"
        picked+=$(echo "$existing" | sed -n "${idx}p")
        picked+=$'\n'
      done
    fi
  fi

  printf "%s\n%s\n" "$picked" "$manual" \
    | awk 'NF>1 && $1 ~ /^ssh-|^ecdsa-|^sk-ssh-/ {print $0}' \
    | awk '!seen[$0]++'
}

print_summary() {
  local CTID="$1" HOSTNAME="$2" OS="$3" TYPE="$4" DISK="$5" CORES="$6" RAM="$7" \
        TPL_STORE="$8" ROOT_STORE="$9" DATA_STORE="${10}" TEMPLATE="${11}" PORT="${12}" TAGS="${13}"

  echo -e "\n${BOLD}${APP}${CLR}"
  echo -e "${GN}✓${CLR} Container ID: ${BOLD}${CTID}${CLR}"
  echo -e "${GN}✓${CLR} Hostname: ${BOLD}${HOSTNAME}${CLR}"
  echo -e "${GN}✓${CLR} OS: ${BOLD}${OS}${CLR}"
  echo -e "${GN}✓${CLR} Type: ${BOLD}${TYPE}${CLR}"
  echo -e "${GN}✓${CLR} RootFS: ${BOLD}${DISK}GiB${CLR}  Cores: ${BOLD}${CORES}${CLR}  RAM: ${BOLD}${RAM}MiB${CLR}"
  echo -e "${GN}✓${CLR} Template: ${BOLD}${TEMPLATE}${CLR} (storage: ${TPL_STORE})"
  echo -e "${GN}✓${CLR} RootFS storage: ${BOLD}${ROOT_STORE}${CLR}"
  echo -e "${GN}✓${CLR} Data storage: ${BOLD}${DATA_STORE}${CLR} (mp0 -> /opt/ts)"
  echo -e "${GN}✓${CLR} Port: ${BOLD}${PORT}${CLR}"
  echo -e "${GN}✓${CLR} Tags: ${BOLD}${TAGS}${CLR}\n"
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

  # select storages from existing
  msg "Selecting storages..."
  local TEMPLATE_STORAGE ROOTFS_STORAGE DATA_STORAGE
  TEMPLATE_STORAGE="$(select_storage "TEMPLATE STORAGE" "vztmpl" "LXC templates (vztmpl)")"
  ROOTFS_STORAGE="$(select_storage "ROOTFS STORAGE" "rootdir" "container rootfs (rootdir)")"
  DATA_STORAGE="$(select_storage "DATA STORAGE" "rootdir" "data volume for /opt/ts (rootdir)")"

  # parameters
  local HOSTNAME ROOTFS_SIZE DATA_SIZE RAM CORES BRIDGE IPCONF TZ PORT TAGS
  local ENABLE_SSH="auto"   # auto|yes|no

  if [ "$MODE" = "advanced" ]; then
    HOSTNAME="$(ask "HOSTNAME" "Container hostname" "$DEF_HOSTNAME")"
    ROOTFS_SIZE="$(ask "ROOTFS SIZE" "RootFS size (GiB)" "$DEF_ROOTFS_SIZE")"
    DATA_SIZE="$(ask "DATA SIZE" "/opt/ts volume size (GiB)" "$DEF_DATA_SIZE")"
    RAM="$(ask "RAM" "RAM (MiB)" "$DEF_RAM")"
    CORES="$(ask "CORES" "CPU cores" "$DEF_CORES")"
    BRIDGE="$(ask "NETWORK" "Bridge (e.g. vmbr0)" "$DEF_BRIDGE")"
    IPCONF="$(ask "NETWORK" "IPv4 (dhcp OR ip/mask,gw=gwip)" "$DEF_IPCONF")"
    TZ="$(ask "TIMEZONE" "Timezone" "$DEF_TZ")"
    PORT="$(ask "PORT" "TorrServer port" "$DEF_PORT")"
    TAGS="$(ask "TAGS" "Container tags (semicolon-separated)" "$DEF_TAGS")"

    local ssh_mode
    ssh_mode="$(menu "SSH" "Enable SSH server inside CT?" "auto" \
      "auto" "Auto (enable if password or keys set)" \
      "yes"  "Yes" \
      "no"   "No")"
    ENABLE_SSH="$ssh_mode"
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
    ENABLE_SSH="auto"
  fi

  # Alpine template selection
  msg "Selecting Alpine template..."
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
  ok "Template ready: $TEMPLATE"

  # Auth
  msg "Authentication (you can set BOTH password and SSH keys)"
  local ROOT_PW SSH_KEYS SSH_KEYS_FILE=""
  ROOT_PW="$(password_prompt_optional)"
  SSH_KEYS="$(select_ssh_keys_optional || true)"
  SSH_KEYS="$(echo "$SSH_KEYS" | awk 'NF>0')"

  if [ -n "${SSH_KEYS:-}" ]; then
    SSH_KEYS_FILE="$(mktemp)"
    printf "%s\n" "$SSH_KEYS" >"$SSH_KEYS_FILE"
    ok "SSH keys selected: $(wc -l <"$SSH_KEYS_FILE")"
  else
    ok "SSH keys: none"
  fi

  # Summary
  print_summary "$CTID" "$HOSTNAME" "alpine" "unprivileged" "$ROOTFS_SIZE" "$CORES" "$RAM" \
    "$TEMPLATE_STORAGE" "$ROOTFS_STORAGE" "$DATA_STORAGE" "$TEMPLATE" "$PORT" "$TAGS"

  if have_whiptail; then
    yesno "CONFIRM" "Proceed with container creation?" 1 || die "Cancelled."
  else
    read -r -p "Proceed? (y/n) [y]: " yn
    yn="${yn:-y}"
    [[ "$yn" =~ ^[Yy]$ ]] || die "Cancelled."
  fi

  # Build pct create args
  msg "Creating LXC..."
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

  # root password (optional)
  if [ -n "${ROOT_PW:-}" ]; then
    PCT_ARGS+=( --password "$ROOT_PW" )
  fi

  # ssh keys (optional)
  if [ -n "${SSH_KEYS_FILE:-}" ]; then
    PCT_ARGS+=( --ssh-public-keys "$SSH_KEYS_FILE" )
  fi

  pct "${PCT_ARGS[@]}"
  ok "LXC created and started"

  # Provision inside CT
  msg "Provisioning inside container..."
  cat > /tmp/provision-torrserver-alpine.sh <<'EOF'
#!/bin/sh
set -eu

: "${TZ:=Europe/Moscow}"
: "${PORT:=8090}"
: "${ENABLE_SSH:=auto}"   # auto|yes|no
: "${ROOT_PW_SET:=0}"     # 1/0
: "${SSH_KEYS_SET:=0}"    # 1/0

apk add --no-cache ca-certificates curl wget tzdata bash gcompat libc6-compat

# timezone
if [ -e "/usr/share/zoneinfo/${TZ}" ]; then
  cp "/usr/share/zoneinfo/${TZ}" /etc/localtime
  echo "${TZ}" > /etc/timezone
fi

# Data layout: one volume /opt/ts
mkdir -p /opt/ts/config /opt/ts/cache /opt/ts/log
ln -snf /opt/ts/cache /opt/ts/torrents

# service user + permissions (fix restart loops due to /opt/ts root:root)
addgroup -S torrserver 2>/dev/null || true
adduser  -S -D -H -s /sbin/nologin -G torrserver torrserver 2>/dev/null || true
chown -R torrserver:torrserver /opt/ts

# download TorrServer
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  TSARCH="amd64" ;;
  aarch64) TSARCH="arm64" ;;
  armv7*|armv7l) TSARCH="arm7" ;;
  armv6*|armv6l) TSARCH="arm5" ;;
  i386|i686) TSARCH="386" ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

BIN="/usr/local/bin/torrserver"
URL="https://github.com/YouROK/TorrServer/releases/latest/download/TorrServer-linux-${TSARCH}"
curl -L -o "${BIN}" "${URL}"
chmod +x "${BIN}"

# env config (compose-like)
cat > /etc/conf.d/torrserver <<CONF
TZ=${TZ}
TS_PORT=${PORT}
TS_DONTKILL=1
TS_CONF_PATH=/opt/ts/config
TS_TORR_DIR=/opt/ts/cache
TS_LOG_PATH=/opt/ts/log/torrserver.log
# TS_HTTPAUTH=1
# TS_RDB=1
CONF

cat > /usr/local/bin/torrserver-run <<'RUN'
#!/usr/bin/env bash
set -euo pipefail
set -a
[ -f /etc/conf.d/torrserver ] && . /etc/conf.d/torrserver
set +a

ARGS=( "--port" "${TS_PORT:-8090}"
       "--path" "${TS_CONF_PATH:-/opt/ts/config}"
       "--torrentsdir" "${TS_TORR_DIR:-/opt/ts/cache}" )

[ "${TS_DONTKILL:-0}" = "1" ] && ARGS+=( "--dontkill" )
[ "${TS_HTTPAUTH:-0}" = "1" ] && ARGS+=( "--httpauth" )
[ "${TS_RDB:-0}" = "1" ] && ARGS+=( "--rdb" )

if [ -n "${TS_LOG_PATH:-}" ]; then
  mkdir -p "$(dirname "${TS_LOG_PATH}")"
  ARGS+=( "--logpath" "${TS_LOG_PATH}" )
fi

exec /usr/local/bin/torrserver "${ARGS[@]}"
RUN
chmod +x /usr/local/bin/torrserver-run

# OpenRC service
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

depend() { need net; }
INIT
chmod +x /etc/init.d/torrserver

rc-update add torrserver default
rc-service torrserver restart || rc-service torrserver start

# Decide whether to enable SSH
enable_ssh=0
case "${ENABLE_SSH}" in
  yes) enable_ssh=1 ;;
  no) enable_ssh=0 ;;
  auto)
    if [ "${ROOT_PW_SET}" = "1" ] || [ "${SSH_KEYS_SET}" = "1" ]; then
      enable_ssh=1
    fi
    ;;
esac

if [ "$enable_ssh" = "1" ]; then
  apk add --no-cache openssh
  ssh-keygen -A

  # root login policy:
  # - if password set -> PermitRootLogin yes
  # - else -> keys only
  if [ "${ROOT_PW_SET}" = "1" ]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config || true
    grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
  else
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config || true
    grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config
  fi

  rc-update add sshd default
  rc-service sshd restart || rc-service sshd start
fi
EOF

  chmod +x /tmp/provision-torrserver-alpine.sh
  pct push "$CTID" /tmp/provision-torrserver-alpine.sh /root/provision-torrserver.sh

  local ROOT_PW_SET=0 SSH_KEYS_SET=0
  [ -n "${ROOT_PW:-}" ] && ROOT_PW_SET=1
  [ -n "${SSH_KEYS_FILE:-}" ] && SSH_KEYS_SET=1

  pct exec "$CTID" -- env \
    TZ="$TZ" PORT="$PORT" \
    ENABLE_SSH="$ENABLE_SSH" \
    ROOT_PW_SET="$ROOT_PW_SET" SSH_KEYS_SET="$SSH_KEYS_SET" \
    sh /root/provision-torrserver.sh

  ok "Provision complete"

  # cleanup
  [ -n "${SSH_KEYS_FILE:-}" ] && rm -f "$SSH_KEYS_FILE" || true

  echo
  ok "Created CTID: $CTID"
  ok "Tags: $TAGS"
  ok "TorrServer: http://<CT_IP>:${PORT}"
  ok "Check service: pct exec ${CTID} -- rc-service torrserver status"
  ok "Check port: pct exec ${CTID} -- sh -lc 'apk add --no-cache iproute2-ss >/dev/null 2>&1 || true; ss -lntp | grep :${PORT} || true'"
}

main "$@"
