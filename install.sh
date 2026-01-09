#!/usr/bin/env bash
set -euo pipefail

APP="TorrServer (Alpine LXC)"

DEF_HOSTNAME="torrserver"
DEF_TEMPLATE_STORAGE="local"   # storage с LXC templates (vztmpl)
DEF_ROOTFS_STORAGE="local-lvm" # storage для rootfs
DEF_ROOTFS_SIZE="1"            # GiB
DEF_DATA_STORAGE="local-lvm"   # storage для отдельного тома /opt/ts
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
  need_cmd awk
  need_cmd grep
  need_cmd sort
  need_cmd tail
  need_cmd dpkg

  # Авто-ID контейнера
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
  es
  
