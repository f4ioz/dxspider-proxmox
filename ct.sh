#!/usr/bin/env bash
# DXSpider on Proxmox — CT bootstrap.
#
# À exécuter sur l'HÔTE Proxmox :
#   bash <(curl -fsSL https://raw.githubusercontent.com/f4ioz/dxspider-proxmox/main/ct.sh)
#
# Crée un CT Debian 12 LXC et y déploie DXSpider (port 7300 telnet).
# Idempotent : si le CT existe déjà, on ne le recrée pas.

set -Eeuo pipefail

# ── couleurs / helpers (style community-scripts) ───────────────────────
RD='\033[0;31m'
YW='\033[0;33m'
GN='\033[0;32m'
BL='\033[0;34m'
DM='\033[2m'
CL='\033[0m'
CM='✔'
XX='✖'
ARROW='»'

msg_info()  { echo -ne " ${YW}${ARROW}${CL} $1..."; }
msg_ok()    { echo -e   " ${GN}${CM}${CL} $1"; }
msg_warn()  { echo -e   " ${YW}!${CL} $1"; }
msg_error() { echo -e   " ${RD}${XX}${CL} $1"; }
header() {
  cat <<'EOF'

   ____  __  __  ____            _      _
  |  _ \ \ \/ / / ___| _ __ (_) __| | ___| |__
  | | | | \  /  \___ \| '_ \| |/ _` |/ _ \ '__|
  | |_| | /  \   ___) | |_) | | (_| |  __/ |
  |____/ /_/\_\ |____/| .__/|_|\__,_|\___|_|
                       |_|     DX cluster node — Proxmox CT installer

EOF
}
trap 'msg_error "Aborted (line $LINENO)"; exit 1' ERR

[[ "$(id -u)" -eq 0 ]] || { echo "This script must run as root on a Proxmox host."; exit 1; }
command -v pveversion >/dev/null || { echo "pveversion not found — not on a Proxmox host?"; exit 1; }
command -v pct        >/dev/null || { echo "pct not found"; exit 1; }

header

# ── prompt helpers ─────────────────────────────────────────────────────
ask() {
  local var=$1 prompt=$2 default=$3
  local reply
  if [[ -n "$default" ]]; then
    read -r -p "  $prompt [$default]: " reply
    eval "$var=\${reply:-$default}"
  else
    read -r -p "  $prompt: " reply
    eval "$var=\$reply"
  fi
}
ask_yn() {
  local var=$1 prompt=$2 default=${3:-y}
  local reply
  read -r -p "  $prompt [$default]: " reply
  reply=${reply:-$default}
  case "${reply,,}" in y|yes|o|oui) eval "$var=1" ;; *) eval "$var=0" ;; esac
}

# ── défauts / détection ────────────────────────────────────────────────
NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo 200)
DEFAULT_STORAGE=$(pvesm status -content rootdir 2>/dev/null | awk 'NR==2{print $1}' || echo "local-lvm")
DEFAULT_BRIDGE=$(grep -oE 'iface vmbr[0-9]+' /etc/network/interfaces 2>/dev/null | awk '{print $2}' | head -1 || echo "vmbr0")

echo -e "${BL}Configuration du Conteneur${CL}"
ask CT_ID         "ID du CT"           "$NEXT_ID"
ask HOSTNAME      "Hostname"           "dxspider"
ask STORAGE       "Storage"            "$DEFAULT_STORAGE"
ask BRIDGE        "Bridge réseau"      "$DEFAULT_BRIDGE"
ask DISK_GB       "Taille disque (Go)" "4"
ask RAM_MB        "RAM (Mo)"           "512"
ask CPU_CORES     "CPU cores"          "1"
ask NET_MODE      "Réseau (dhcp|static)" "dhcp"
if [[ "$NET_MODE" == "static" ]]; then
  ask NET_IP      "IP/CIDR (ex: 192.168.1.50/24)" ""
  ask NET_GW      "Gateway"            ""
else
  NET_IP="dhcp"; NET_GW=""
fi
ask CT_PASSWORD   "Mot de passe root du CT"  "$(openssl rand -base64 12 | tr -d /=+)"

echo
echo -e "${BL}Configuration DXSpider (sera demandée à l'intérieur du CT)${CL}"
echo -e "${DM}  callsign, locator, peers — interactif après boot.${CL}"
echo

ask_yn CONFIRM "Confirmer la création ?" "y"
[[ $CONFIRM -eq 1 ]] || { msg_warn "Abandon utilisateur"; exit 0; }

# ── template Debian 12 ────────────────────────────────────────────────
msg_info "Recherche du template Debian 12"
TPL=$(pveam list "$DEFAULT_STORAGE" 2>/dev/null | awk '/debian-12-standard.*\.tar\.zst/{print $1}' | tail -1 || true)
if [[ -z "$TPL" ]]; then
  msg_info "Téléchargement du template (peut prendre 1-2 min)"
  TPL_NAME=$(pveam available -section system 2>/dev/null | awk '/debian-12-standard/{print $2}' | tail -1)
  [[ -z "$TPL_NAME" ]] && { msg_error "template introuvable"; exit 1; }
  pveam download "$DEFAULT_STORAGE" "$TPL_NAME" >/dev/null
  TPL="$DEFAULT_STORAGE:vztmpl/$TPL_NAME"
fi
msg_ok "Template : $TPL"

# ── création CT ────────────────────────────────────────────────────────
if pct status "$CT_ID" >/dev/null 2>&1; then
  msg_warn "CT $CT_ID existe déjà — on ne recrée pas, on relance l'install dedans"
  pct status "$CT_ID" | grep -q running || pct start "$CT_ID"
else
  msg_info "Création du CT $CT_ID"
  NET_OPT="name=eth0,bridge=$BRIDGE"
  if [[ "$NET_MODE" == "static" ]]; then
    NET_OPT="$NET_OPT,ip=$NET_IP,gw=$NET_GW"
  else
    NET_OPT="$NET_OPT,ip=dhcp"
  fi
  pct create "$CT_ID" "$TPL" \
    --hostname "$HOSTNAME" \
    --cores "$CPU_CORES" \
    --memory "$RAM_MB" \
    --swap 0 \
    --rootfs "$STORAGE:$DISK_GB" \
    --net0 "$NET_OPT" \
    --features nesting=1 \
    --unprivileged 1 \
    --onboot 1 \
    --password "$CT_PASSWORD" \
    --description "DXSpider DX-cluster node — installé via f4ioz.fr/proxmox/dxspider" \
    --ostype debian >/dev/null
  pct start "$CT_ID" >/dev/null
  msg_ok "CT $CT_ID créé et démarré"
  msg_info "Attente du réseau"
  for i in {1..20}; do
    if pct exec "$CT_ID" -- ping -W1 -c1 1.1.1.1 >/dev/null 2>&1; then break; fi
    sleep 1
  done
  msg_ok "Réseau OK"
fi

# ── push install.sh ───────────────────────────────────────────────────
msg_info "Téléchargement et exécution de install.sh dans le CT"
INSTALL_URL="${INSTALL_URL:-https://raw.githubusercontent.com/f4ioz/dxspider-proxmox/main/install.sh}"
pct exec "$CT_ID" -- bash -c "apt-get -qq update >/dev/null 2>&1 && apt-get -qq install -y curl >/dev/null 2>&1"
pct exec "$CT_ID" -- bash -c "curl -fsSL '$INSTALL_URL' -o /root/install.sh && chmod +x /root/install.sh"
echo
msg_ok "Lancement de l'installation interactive (DXSpider) — répondre aux prompts ↓"
echo
pct exec "$CT_ID" -- bash /root/install.sh

# ── récap ─────────────────────────────────────────────────────────────
CT_IP=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')
echo
echo -e "${GN}════════════════════════════════════════════════════${CL}"
msg_ok "DXSpider installé"
echo -e "${BL}  CT ID    :${CL} $CT_ID"
echo -e "${BL}  Hostname :${CL} $HOSTNAME"
echo -e "${BL}  IP       :${CL} $CT_IP"
echo -e "${BL}  Telnet   :${CL} ${GN}telnet $CT_IP 7300${CL}  (login = ton call)"
echo -e "${BL}  Logs     :${CL} pct exec $CT_ID -- journalctl -u dxspider -f"
echo -e "${BL}  Stop     :${CL} pct exec $CT_ID -- systemctl stop dxspider"
echo -e "${GN}════════════════════════════════════════════════════${CL}"
