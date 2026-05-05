#!/usr/bin/env bash
# DXSpider — installation interactive dans un CT Debian 12.
# Téléchargé et exécuté par ct.sh (Proxmox host).

set -Eeuo pipefail

RD='\033[0;31m'; YW='\033[0;33m'; GN='\033[0;32m'; BL='\033[0;34m'; DM='\033[2m'; CL='\033[0m'
msg_info()  { echo -ne " ${YW}»${CL} $1..."; }
msg_ok()    { echo -e   " ${GN}✔${CL} $1"; }
msg_warn()  { echo -e   " ${YW}!${CL} $1"; }
msg_error() { echo -e   " ${RD}✖${CL} $1"; }
trap 'msg_error "Aborted (line $LINENO)"; exit 1' ERR

ask() {
  local var=$1 prompt=$2 default=$3 reply
  if [[ -n "$default" ]]; then
    read -r -p "  $prompt [$default]: " reply
    eval "$var=\${reply:-$default}"
  else
    read -r -p "  $prompt: " reply
    eval "$var=\$reply"
  fi
}

[[ "$(id -u)" -eq 0 ]] || { msg_error "Doit tourner en root"; exit 1; }

# ── 1. dépendances ────────────────────────────────────────────────────
msg_info "Installation des dépendances Perl"
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null
apt-get -qq install -y --no-install-recommends \
  perl ca-certificates curl git \
  libtimedate-perl libnet-telnet-perl libdigest-sha-perl \
  libdbi-perl libdbd-sqlite3-perl libdata-dumper-simple-perl \
  libio-socket-ssl-perl libnet-cidr-lite-perl libnet-cidr-perl \
  libtime-hires-perl libio-socket-inet6-perl libxml-simple-perl \
  libfile-find-rule-perl >/dev/null
msg_ok "Dépendances installées"

# ── 2. user sysop ─────────────────────────────────────────────────────
if ! id sysop >/dev/null 2>&1; then
  msg_info "Création du user sysop"
  useradd -m -s /bin/bash sysop
  msg_ok "User sysop créé"
fi

# ── 3. paramètres interactifs ─────────────────────────────────────────
echo
echo -e "${BL}Configuration DXSpider — réponds aux questions${CL}"
ask MYCALL    "Ton indicatif (sans suffix node)" "F4IOZ"
ask NODECALL  "Indicatif du node (suffix '-1' standard)" "${MYCALL}-1"
ask MYNAME    "Prénom du sysop"                 "Olivier"
ask MYEMAIL   "Email sysop"                     ""
ask MYLOC     "Locator (4 ou 6 chars)"          "JN18FS"
ask MYQTH     "QTH (ville, pays)"               "Creteil, France"

# locator → lat/lon (perl one-liner)
read -r MYLAT MYLON <<<"$(perl -e '
  my $loc = uc($ARGV[0]);
  my @c = split //, $loc;
  my $lon = (ord($c[0])-65)*20 - 180;
  my $lat = (ord($c[1])-65)*10 - 90;
  $lon += $c[2]*2;
  $lat += $c[3]*1;
  if (length($loc) >= 6) {
    $lon += (ord($c[4])-65)*(2/24) + 1/24;
    $lat += (ord($c[5])-65)*(1/24) + 1/48;
  } else { $lon += 1; $lat += 0.5; }
  printf("%.4f %.4f", $lat, $lon);
' "$MYLOC")"
msg_ok "Locator $MYLOC → ($MYLAT, $MYLON)"

echo
echo -e "${BL}Peers DX-cluster${CL} (le node se connecte à eux pour recevoir le flux global)"
ask PEER1 "Peer 1 (host:port)" "dxc.f5len.org:8000"
ask PEER2 "Peer 2 (host:port)" "dxspider.f6bee.org:7300"
ask PEER3 "Peer 3 (host:port)" "gb7djk.dxcluster.net:7300"

# ── 4. clone DXSpider ────────────────────────────────────────────────
SPIDER_DIR=/home/sysop/spider
if [[ ! -d "$SPIDER_DIR" ]]; then
  msg_info "Clone du dépôt DXSpider"
  sudo -u sysop git clone -b mojo https://www.dxcluster.org/spider.git "$SPIDER_DIR" 2>/dev/null \
    || sudo -u sysop git clone https://github.com/dxspider/dxspider.git "$SPIDER_DIR"
  msg_ok "Source cloné dans $SPIDER_DIR"
fi

# ── 5. premier lancement (création schéma SQLite, etc.) ──────────────
if [[ ! -f "$SPIDER_DIR/local/DXVars.pm" ]]; then
  msg_info "Bootstrap du schéma DXSpider (premier run)"
  sudo -u sysop bash -c "cd $SPIDER_DIR && yes | perl create_sysop.pl" >/dev/null 2>&1 || true
  msg_ok "Schéma initialisé"
fi

# ── 6. génération DXVars.pm ──────────────────────────────────────────
msg_info "Écriture de local/DXVars.pm"
mkdir -p "$SPIDER_DIR/local"
cat > "$SPIDER_DIR/local/DXVars.pm" <<EOF
# DXVars.pm — généré par /proxmox/dxspider/install.sh
package main;
use strict;
use warnings;

\$mycall   = "$NODECALL";
\$myalias  = "$MYCALL";
\$myname   = "$MYNAME";
\$myemail  = "$MYEMAIL";
\$mylatitude  = $MYLAT;
\$mylongitude = $MYLON;
\$myqth    = "$MYQTH";
\$mylocator = "$MYLOC";
\$myregion = "France";
\$mycity   = "$MYQTH";

\$lang = "fr";

# crontab par défaut (les peers sont gérés via fichiers connect/)

1;
EOF
chown sysop:sysop "$SPIDER_DIR/local/DXVars.pm"
msg_ok "DXVars.pm écrit"

# ── 7. fichiers connect/ pour les peers ──────────────────────────────
mkdir -p "$SPIDER_DIR/connect"
gen_peer() {
  local name=$1 hostport=$2
  local host="${hostport%:*}" port="${hostport#*:}"
  local fname="$SPIDER_DIR/connect/$name"
  cat > "$fname" <<EOF
# auto-generated peer
timeout 60
abort connect failed
abort already connected
connect telnet $host $port
'login: ' '$NODECALL'
'>>> ' 'set/dx'
'>>> ' 'set/skim'
client $NODECALL telnet
EOF
  chown sysop:sysop "$fname"
}
gen_peer peer1 "$PEER1"
gen_peer peer2 "$PEER2"
gen_peer peer3 "$PEER3"
msg_ok "3 peers configurés (connect/peer{1,2,3})"

# Les peers doivent aussi être déclarés dans la table 'cluster' interne.
# On le fait au démarrage via une commande sysop.

# ── 8. service systemd ───────────────────────────────────────────────
msg_info "Service systemd dxspider.service"
cat > /etc/systemd/system/dxspider.service <<'EOF'
[Unit]
Description=DXSpider DX-cluster node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=sysop
Group=sysop
WorkingDirectory=/home/sysop/spider/perl
ExecStart=/usr/bin/perl /home/sysop/spider/perl/cluster.pl
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable dxspider >/dev/null 2>&1
msg_ok "Service activé au boot"

# ── 9. start ────────────────────────────────────────────────────────
msg_info "Démarrage de DXSpider"
systemctl restart dxspider
sleep 4

# Verify port 7300
if ss -ltn 2>/dev/null | grep -q ':7300'; then
  msg_ok "DXSpider écoute sur :7300"
else
  msg_warn "Port 7300 pas encore en écoute — vérifier 'journalctl -u dxspider -n 50'"
fi

# ── 10. récap ───────────────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')
echo
echo -e "${GN}╔════════════════════════════════════════════════════════════╗${CL}"
echo -e "${GN}║  DXSpider opérationnel${CL}"
echo -e "${GN}╠════════════════════════════════════════════════════════════╣${CL}"
echo -e "  ${BL}Node    :${CL} $NODECALL"
echo -e "  ${BL}Sysop   :${CL} $MYCALL ($MYNAME)"
echo -e "  ${BL}IP CT   :${CL} $IP"
echo -e "  ${BL}Telnet  :${CL} ${GN}telnet $IP 7300${CL}  (login = ton indicatif)"
echo -e "  ${BL}Peers   :${CL} $PEER1 / $PEER2 / $PEER3"
echo -e "${GN}╠════════════════════════════════════════════════════════════╣${CL}"
echo -e "  ${BL}Logs    :${CL} journalctl -u dxspider -f"
echo -e "  ${BL}Stop    :${CL} systemctl stop dxspider"
echo -e "  ${BL}Restart :${CL} systemctl restart dxspider"
echo -e "  ${BL}Config  :${CL} $SPIDER_DIR/local/DXVars.pm"
echo -e "  ${BL}Peers cfg:${CL} $SPIDER_DIR/connect/peer{1,2,3}"
echo -e "${GN}╠════════════════════════════════════════════════════════════╣${CL}"
echo -e "  ${YW}À FAIRE${CL} : depuis telnet, en sysop, taper :"
echo -e "    ${DM}set/sys${CL}                  (passer en mode sysop)"
echo -e "    ${DM}create/node $NODECALL${CL}    (déclarer ton propre node)"
echo -e "    ${DM}init peer1 peer2 peer3${CL}  (initier la connexion peers)"
echo -e "${GN}╚════════════════════════════════════════════════════════════╝${CL}"
