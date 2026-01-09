#!/usr/bin/env bash
set -euo pipefail

APP="TorrServer (Alpine LXC)"
DEF_CTID="120"
DEF_HOSTNAME="torrserver"
DEF_STORAGE="local-lvm"          # rootfs storage
DEF_TEMPLATE_STORAGE="local"     # where templates are stored (vztmpl)
DEF_DISK="2"                     # GiB (TorrServer сам по себе лёгкий)
DEF_RAM="256"                    # MiB
DEF_CORES="1"
DEF_BRIDGE="vmbr0"
DEF_IPCONF="dhcp"
DEF_TZ="Europe/Moscow"
DEF_PORT="8090"
DEF_HOSTDATA="/srv/pve/torrserver"  # host dirs -> bind mounts

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }

ask() {
  local title="$1" prompt="$2" def="$3" out
  if command -v whiptail >/dev/null 2>&1; then
    out=$(whiptail --backtitle "Proxmox VE Helper-Scripts style" --title "$title" \
      --inputbox "$prompt" 9 72 "$def" 3>&1 1>&2 2>&3) || exit 1
    echo "$out"
  else
    read -r -p "$prompt [$def]: " out
    echo "${out:-$def}"
  fi
}

yesno() {
  local title="$1" prompt="$2" def_yes="$3"
  if command -v whiptail >/dev/null 2>&1; then
    if [ "$def_yes" = "1" ]; then
      whiptail --backtitle "Proxmox VE Helper-Scripts style" --title "$title" --yesno "$prompt" 9 72
    else
      whiptail --backtitle "Proxmox VE Helper-Scripts style" --title "$title" --yesno "$prompt" 9 72 --defaultno
    fi
    return $?
  else
    local ans
    read -r -p "$prompt (y/n) [$( [ "$def_yes" = "1" ] && echo y || echo n )]: " ans
    ans="${ans:-$( [ "$def_yes" = "1" ] && echo y || echo n )}"
    [[ "$ans" =~ ^[Yy]$ ]]
  fi
}

pick_latest_alpine_template() {
  local arch="${1}"  # amd64/arm64
  local tpl
  # output format: "system alpine-3.xx-default_YYYYMMDD_amd64.tar.xz"
  tpl="$(
    pveam available --section system \
      | awk '{print $2}' \
      | grep -E "^alpine-[0-9.]+-default_[0-9]+_${arch}\.tar\.xz$" \
      | sort -V \
      | tail -1
  )"
  echo "$tpl"
}

main() {
  [ "$(id -u)" -eq 0 ] || { echo "Run as root on Proxmox node."; exit 1; }
  need_cmd pct
  need_cmd pveam
  need_cmd awk
  need_cmd grep
  need_cmd sort
  need_cmd tail

  local CTID="$DEF_CTID"
  local HOSTNAME="$DEF_HOSTNAME"
  local STORAGE="$DEF_STORAGE"
  local DISK="$DEF_DISK"
  local RAM="$DEF_RAM"
  local CORES="$DEF_CORES"
  local BRIDGE="$DEF_BRIDGE"
  local IPCONF="$DEF_IPCONF"
  local TZ="$DEF_TZ"
  local PORT="$DEF_PORT"
  local HOSTDATA="$DEF_HOSTDATA"
  local TEMPLATE_STORAGE="$DEF_TEMPLATE_STORAGE"

  if yesno "SETUP" "Use default settings (but ask for port)?" 1; then
    PORT="$(ask "PORT" "TorrServer port" "$PORT")"
  else
    CTID="$(ask "CTID" "Container ID" "$CTID")"
    HOSTNAME="$(ask "HOSTNAME" "Container hostname" "$HOSTNAME")"
    STORAGE="$(ask "STORAGE" "RootFS storage (e.g. local-lvm/zfs/dir)" "$STORAGE")"
    DISK="$(ask "DISK" "Disk size (GiB)" "$DISK")"
    RAM="$(ask "RAM" "RAM (MiB)" "$RAM")"
    CORES="$(ask "CORES" "CPU cores" "$CORES")"
    BRIDGE="$(ask "NETWORK" "Bridge (e.g. vmbr0)" "$BRIDGE")"
    IPCONF="$(ask "NETWORK" "IP config (dhcp OR ip/mask,gw=gwip)" "$IPCONF")"
    TZ="$(ask "TIMEZONE" "Timezone" "$TZ")"
    PORT="$(ask "PORT" "TorrServer port" "$PORT")"
    HOSTDATA="$(ask "DATA DIR" "Host data dir for bind-mounts" "$HOSTDATA")"
    TEMPLATE_STORAGE="$(ask "TEMPLATE STORAGE" "Template storage (usually local)" "$TEMPLATE_STORAGE")"
  fi

  mkdir -p "${HOSTDATA}/config" "${HOSTDATA}/torrents" "${HOSTDATA}/log"

  pveam update

  local PVE_ARCH
  PVE_ARCH="$(dpkg --print-architecture)"
  local TPL_ARCH="amd64"
  case "$PVE_ARCH" in
    amd64) TPL_ARCH="amd64" ;;
    arm64) TPL_ARCH="arm64" ;;
    *) echo "Unsupported host arch for this script: $PVE_ARCH"; exit 1 ;;
  esac

  local TEMPLATE
  TEMPLATE="$(pick_latest_alpine_template "$TPL_ARCH")"
  if [ -z "${TEMPLATE:-}" ]; then
    TEMPLATE="alpine-3.22-default_20250617_amd64.tar.xz"
  fi

  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}" || true

  pct create "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --ostype alpine \
    --hostname "${HOSTNAME}" \
    --cores "${CORES}" --memory "${RAM}" --swap 128 \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IPCONF}" \
    --unprivileged 1 \
    --onboot 1 \
    --mp0 "${HOSTDATA}/config,mp=/opt/ts/config" \
    --mp1 "${HOSTDATA}/torrents,mp=/opt/ts/torrents" \
    --mp2 "${HOSTDATA}/log,mp=/opt/ts/log" \
    --start 1

  cat > /tmp/provision-torrserver-alpine.sh <<EOF
#!/bin/sh
set -eu

# пакеты
apk add --no-cache ca-certificates curl wget tzdata bash gcompat

# timezone
if [ -e "/usr/share/zoneinfo/${TZ}" ]; then
  cp "/usr/share/zoneinfo/${TZ}" /etc/localtime
  echo "${TZ}" > /etc/timezone
fi

# каталоги (будут перекрыты mp0/mp1/mp2, но пусть существуют)
mkdir -p /opt/ts/config /opt/ts/torrents /opt/ts/log

# user/group
addgroup -S torrserver 2>/dev/null || true
adduser  -S -D -H -s /sbin/nologin -G torrserver torrserver 2>/dev/null || true

# arch -> TorrServer release asset name
ARCH="\$(uname -m)"
case "\$ARCH" in
  x86_64)  TSARCH="amd64" ;;
  aarch64) TSARCH="arm64" ;;
  armv7*|armv7l) TSARCH="arm7" ;;
  armv6*|armv6l) TSARCH="arm5" ;;
  i386|i686) TSARCH="386" ;;
  *) echo "Unsupported arch: \$ARCH"; exit 1 ;;
esac

BIN="/usr/local/bin/torrserver"
URL="https://github.com/YouROK/TorrServer/releases/latest/download/TorrServer-linux-\${TSARCH}"
curl -L -o "\${BIN}" "\${URL}"
chmod +x "\${BIN}"

# env (аналог docker-compose environment)
cat > /etc/conf.d/torrserver <<CONF
TZ=${TZ}
TS_PORT=${PORT}
TS_DONTKILL=1
TS_CONF_PATH=/opt/ts/config
TS_TORR_DIR=/opt/ts/torrents
TS_LOG_PATH=/opt/ts/log/torrserver.log
# опционально:
# TS_HTTPAUTH=1
# TS_RDB=1
CONF

# wrapper (собирает флаги как в compose)
cat > /usr/local/bin/torrserver-run <<'RUN'
#!/usr/bin/env bash
set -euo pipefail
set -a
[ -f /etc/conf.d/torrserver ] && . /etc/conf.d/torrserver
set +a

ARGS=( "--port" "${TS_PORT:-8090}"
       "--path" "${TS_CONF_PATH:-/opt/ts/config}"
       "--torrentsdir" "${TS_TORR_DIR:-/opt/ts/torrents}" )

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

# OpenRC service (respawn)
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
  pct push "${CTID}" /tmp/provision-torrserver-alpine.sh /root/provision-torrserver.sh
  pct exec "${CTID}" -- sh /root/provision-torrserver.sh

  echo
  echo "OK: http://<CT_IP>:${PORT}"
  echo "Logs: ${HOSTDATA}/log (host)  -> /opt/ts/log (ct)"
  echo "Manage: pct exec ${CTID} -- rc-service torrserver {status|restart|stop|start}"
}

main "$@"
