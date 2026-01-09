#!/usr/bin/env bash
set -euo pipefail

APP="TorrServer (Alpine LXC)"

DEF_HOSTNAME="torrserver"
DEF_TEMPLATE_STORAGE="local"     # где лежат LXC templates (vztmpl)
DEF_ROOTFS_STORAGE="local-lvm"   # storage для rootfs
DEF_ROOTFS_SIZE="1"              # GiB
DEF_DATA_STORAGE="local-lvm"     # storage для отдельного тома /opt/ts
DEF_DATA_SIZE="4"                # GiB

DEF_RAM="256"                    # MiB
DEF_CORES="1"
DEF_BRIDGE="vmbr0"
DEF_IPCONF="dhcp"
DEF_TZ="Europe/Moscow"
DEF_PORT="8090"

FALLBACK_TEMPLATE="alpine-3.22-default_20250617_amd64.tar.xz"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }

ask() {
  local title="$1" prompt="$2" def="$3" out
  if command -v whiptail >/dev/null 2>&1; then
    out=$(whiptail --backtitle "Proxmox VE Helper-Scripts style" --title "$title" \
      --inputbox "$prompt" 9 74 "$def" 3>&1 1>&2 2>&3) || exit 1
    echo "$out"
  else
    read -r -p "$prompt [$def]: " out
    echo "${out:-$def}"
  fi
}

pick_latest_alpine_template() {
  local arch="$1" # amd64/arm64
  pveam available --section system \
    | awk '{print $2}' \
    | grep -E "^alpine-[0-9.]+-default_[0-9]+_${arch}\.tar\.xz$" \
    | sort -V \
    | tail -1
}

main() {
  [ "$(id -u)" -eq 0 ] || { echo "Run as root on Proxmox node."; exit 1; }

  need_cmd pct
  need_cmd pveam
  need_cmd pvesh
  need_cmd dpkg
  need_cmd awk
  need_cmd grep
  need_cmd sort
  need_cmd tail

  # Авто-CTID
  local CTID
  CTID="$(pvesh get /cluster/nextid)"

  # Всегда спрашиваем параметры (Enter = дефолт)
  local HOSTNAME TEMPLATE_STORAGE ROOTFS_STORAGE ROOTFS_SIZE DATA_STORAGE DATA_SIZE
  local RAM CORES BRIDGE IPCONF TZ PORT

  HOSTNAME="$(ask "HOSTNAME" "Container hostname" "$DEF_HOSTNAME")"
  TEMPLATE_STORAGE="$(ask "TEMPLATE STORAGE" "Template storage (usually local)" "$DEF_TEMPLATE_STORAGE")"
  ROOTFS_STORAGE="$(ask "ROOTFS STORAGE" "RootFS storage (e.g. local-lvm/zfs/dir)" "$DEF_ROOTFS_STORAGE")"
  ROOTFS_SIZE="$(ask "ROOTFS SIZE" "RootFS size (GiB)" "$DEF_ROOTFS_SIZE")"
  DATA_STORAGE="$(ask "DATA STORAGE" "Storage for /opt/ts volume" "$DEF_DATA_STORAGE")"
  DATA_SIZE="$(ask "DATA SIZE" "/opt/ts volume size (GiB)" "$DEF_DATA_SIZE")"
  RAM="$(ask "RAM" "RAM (MiB)" "$DEF_RAM")"
  CORES="$(ask "CORES" "CPU cores" "$DEF_CORES")"
  BRIDGE="$(ask "NETWORK" "Bridge (e.g. vmbr0)" "$DEF_BRIDGE")"
  IPCONF="$(ask "NETWORK" "IP config (dhcp OR ip/mask,gw=gwip)" "$DEF_IPCONF")"
  TZ="$(ask "TIMEZONE" "Timezone" "$DEF_TZ")"
  PORT="$(ask "PORT" "TorrServer port" "$DEF_PORT")"

  pveam update

  # arch хоста -> arch шаблона
  local host_arch tpl_arch
  host_arch="$(dpkg --print-architecture)"
  case "$host_arch" in
    amd64) tpl_arch="amd64" ;;
    arm64) tpl_arch="arm64" ;;
    *) echo "Unsupported PVE arch: $host_arch"; exit 1 ;;
  esac

  # Подбираем последний Alpine template, иначе fallback
  local template
  template="$(pick_latest_alpine_template "$tpl_arch" || true)"
  [ -n "${template:-}" ] || template="$FALLBACK_TEMPLATE"

  pveam download "$TEMPLATE_STORAGE" "$template" || true

  # Создаём контейнер + отдельный volume под /opt/ts (единая папка для config/cache/log)
  pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${template}" \
    --ostype alpine \
    --hostname "$HOSTNAME" \
    --cores "$CORES" --memory "$RAM" --swap 128 \
    --rootfs "${ROOTFS_STORAGE}:${ROOTFS_SIZE}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IPCONF}" \
    --unprivileged 1 \
    --onboot 1 \
    --mp0 "${DATA_STORAGE}:${DATA_SIZE},mp=/opt/ts" \
    --start 1

  # Provision внутри Alpine (ВАЖНО: heredoc закрывается строго с 0-й колонки)
  cat > /tmp/provision-torrserver-alpine.sh <<'EOF'
#!/bin/sh
set -eu

: "${TZ:=Europe/Moscow}"
: "${PORT:=8090}"

apk add --no-cache ca-certificates curl wget tzdata bash gcompat

# timezone
if [ -e "/usr/share/zoneinfo/${TZ}" ]; then
  cp "/usr/share/zoneinfo/${TZ}" /etc/localtime
  echo "${TZ}" > /etc/timezone
fi

# Единый volume /opt/ts
mkdir -p /opt/ts/config /opt/ts/cache /opt/ts/log
# совместимость с прежним "torrents"
ln -snf /opt/ts/cache /opt/ts/torrents

# user/group
addgroup -S torrserver 2>/dev/null || true
adduser  -S -D -H -s /sbin/nologin -G torrserver torrserver 2>/dev/null || true

# TorrServer latest release
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

# env (аналог compose)
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

# wrapper: env -> args
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

depend() {
  need net
}
INIT
chmod +x /etc/init.d/torrserver

rc-update add torrserver default
rc-service torrserver start
EOF

  chmod +x /tmp/provision-torrserver-alpine.sh
  pct push "$CTID" /tmp/provision-torrserver-alpine.sh /root/provision-torrserver.sh
  pct exec "$CTID" -- env TZ="$TZ" PORT="$PORT" sh /root/provision-torrserver.sh

  echo
  echo "Created CTID: $CTID"
  echo "Open: http://<CT_IP>:${PORT}"
  echo "Manage: pct exec ${CTID} -- rc-service torrserver {status|restart|stop|start}"
}

main "$@"
