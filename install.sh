#!/usr/bin/env bash
set -euo pipefail

APP="TorrServer (Alpine LXC)"

DEF_CTID="120"
DEF_HOSTNAME="torrserver"
DEF_TEMPLATE_STORAGE="local"   # где лежат LXC templates (vztmpl)
DEF_ROOTFS_STORAGE="local-lvm" # rootfs storage
DEF_ROOTFS_SIZE="1"            # GiB
DEF_DATA_STORAGE="local-lvm"   # отдельный том под /opt/ts
DEF_DATA_SIZE="4"              # GiB

DEF_RAM="256"                  # MiB
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
  need_cmd awk
  need_cmd grep
  need_cmd sort
  need_cmd tail

  local CTID="$DEF_CTID"
  local HOSTNAME="$DEF_HOSTNAME"
  local TEMPLATE_STORAGE="$DEF_TEMPLATE_STORAGE"
  local ROOTFS_STORAGE="$DEF_ROOTFS_STORAGE"
  local ROOTFS_SIZE="$DEF_ROOTFS_SIZE"
  local DATA_STORAGE="$DEF_DATA_STORAGE"
  local DATA_SIZE="$DEF_DATA_SIZE"
  local RAM="$DEF_RAM"
  local CORES="$DEF_CORES"
  local BRIDGE="$DEF_BRIDGE"
  local IPCONF="$DEF_IPCONF"
  local TZ="$DEF_TZ"
  local PORT="$DEF_PORT"

  if yesno "SETUP" "Use defaults (but ask port + data volume)?" 1; then
    PORT="$(ask "PORT" "TorrServer port" "$PORT")"
    DATA_STORAGE="$(ask "DATA STORAGE" "Storage for /opt/ts volume" "$DATA_STORAGE")"
    DATA_SIZE="$(ask "DATA SIZE" "/opt/ts volume size (GiB)" "$DATA_SIZE")"
  else
    CTID="$(ask "CTID" "Container ID" "$CTID")"
    HOSTNAME="$(ask "HOSTNAME" "Container hostname" "$HOSTNAME")"
    TEMPLATE_STORAGE="$(ask "TEMPLATE STORAGE" "Template storage (usually local)" "$TEMPLATE_STORAGE")"
    ROOTFS_STORAGE="$(ask "ROOTFS STORAGE" "RootFS storage" "$ROOTFS_STORAGE")"
    ROOTFS_SIZE="$(ask "ROOTFS SIZE" "RootFS size (GiB)" "$ROOTFS_SIZE")"
    DATA_STORAGE="$(ask "DATA STORAGE" "Storage for /opt/ts volume" "$DATA_STORAGE")"
    DATA_SIZE="$(ask "DATA SIZE" "/opt/ts volume size (GiB)" "$DATA_SIZE")"
    RAM="$(ask "RAM" "RAM (MiB)" "$RAM")"
    CORES="$(ask "CORES" "CPU cores" "$CORES")"
    BRIDGE="$(ask "NETWORK" "Bridge (e.g. vmbr0)" "$BRIDGE")"
    IPCONF="$(ask "NETWORK" "IP config (dhcp OR ip/mask,gw=gwip)" "$IPCONF")"
    TZ="$(ask "TIMEZONE" "Timezone" "$TZ")"
    PORT="$(ask "PORT" "TorrServer port" "$PORT")"
  fi

  pveam update

  local host_arch tpl_arch template
  host_arch="$(dpkg --print-architecture)"
  case "$host_arch" in
    amd64) tpl_arch="amd64" ;;
    arm64) tpl_arch="arm64" ;;
    *) echo "Unsupported PVE arch: $host_arch"; exit 1 ;;
  esac

  template="$(pick_latest_alpine_template "$tpl_arch" || true)"
  [ -n "${template:-}" ] || template="$FALLBACK_TEMPLATE"

  # Скачаем template (если уже есть — просто будет ок/ошибка и пойдём дальше)
  pveam download "$TEMPLATE_STORAGE" "$template" || true

  # 1) создаём контейнер + отдельный том под /opt/ts (аналог vo
