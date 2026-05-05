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

# ── 1. locales + dépendances ──────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

msg_info "Génération des locales (en_US.UTF-8, fr_FR.UTF-8)"
apt-get -qq update >/dev/null
apt-get -qq install -y --no-install-recommends locales >/dev/null
sed -i -E 's/^# ?(en_US\.UTF-8|fr_FR\.UTF-8)/\1/' /etc/locale.gen
locale-gen >/dev/null 2>&1
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 >/dev/null 2>&1
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
msg_ok "Locales générées"

msg_info "Installation des dépendances Perl + outils"
apt-get -qq install -y --no-install-recommends \
  perl ca-certificates curl git openssh-server iproute2 telnet vim less \
  libtimedate-perl libnet-telnet-perl libdigest-sha-perl \
  libdbi-perl libdbd-sqlite3-perl libdata-dumper-simple-perl \
  libio-socket-ssl-perl libnet-cidr-lite-perl libnet-cidr-perl \
  libtime-hires-perl libio-socket-inet6-perl libxml-simple-perl \
  libfile-find-rule-perl libmojolicious-perl libcrypt-passwdmd5-perl \
  libio-string-perl libjson-xs-perl libtest-pod-perl libterm-readkey-perl \
  libcurses-perl libev-perl libdata-structure-util-perl libnet-dns-perl \
  libgeo-coordinates-utm-perl libio-socket-timeout-perl libdigest-md5-perl \
  cpanminus build-essential >/dev/null
msg_ok "Dépendances installées"

# Quelques modules CPAN n'ont pas de paquet Debian — on les installe via cpanm
# si manquants après apt. Digest::SHA1 a été retiré de Debian 13 (libdigest-sha1-perl
# n'existe plus) mais reste requis par DXSpider.
msg_info "Vérification des modules Perl complémentaires (cpanm si besoin)"
for mod in Digest::SHA1 Data::Structure::Util Mojolicious Net::Telnet Time::HiRes Math::Round; do
  perl -e "use $mod; 1" 2>/dev/null || cpanm --quiet --notest "$mod" >/dev/null 2>&1 || true
done
msg_ok "Modules Perl OK"

msg_info "Activation SSH (root login par mot de passe)"
sed -i -E 's/^#?\s*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i -E 's/^#?\s*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl enable ssh >/dev/null 2>&1
systemctl restart ssh
msg_ok "SSH actif sur :22 (root + password)"

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
echo -e "${BL}Peers DX-cluster${CL} (optionnel — laisse vide si pas encore d'autorisation)"
echo -e "${DM}  Note : pour recevoir le flux global, il faut peerer avec un sysop ami${CL}"
echo -e "${DM}  (F5LEN, F6BEE, GB7DJK… contacte-les avant). Tu peux ajouter un peer${CL}"
echo -e "${DM}  plus tard via /spider/connect/<nom> + entrée dans /spider/scripts/startup.${CL}"
ask PEER1 "Peer 1 (host:port, vide pour skip)" ""

# ── 4. clone DXSpider ────────────────────────────────────────────────
SPIDER_DIR=/home/sysop/spider
if [[ ! -d "$SPIDER_DIR" ]]; then
  msg_info "Clone du dépôt DXSpider (cascade : github mirror → official → sf tarball)"
  export GIT_TERMINAL_PROMPT=0       # pas de prompt en cas de 401/404
  cloned=0

  # 1. Mirror GitHub maintenu (latchdevel/DXspider, mojo upstream)
  if runuser -u sysop -- git clone --depth 1 \
       https://github.com/latchdevel/DXspider.git "$SPIDER_DIR" >/dev/null 2>&1; then
    cloned=1
  fi

  # 2. Officiel (scm.dxcluster.org)
  if [[ $cloned -eq 0 ]]; then
    runuser -u sysop -- git clone --depth 1 -b mojo \
      https://scm.dxcluster.org/scm/spider.git "$SPIDER_DIR" >/dev/null 2>&1 && cloned=1
  fi

  # 3. Fallback tarball SourceForge
  if [[ $cloned -eq 0 ]]; then
    msg_info "git indisponible — fallback tarball SourceForge"
    TGZ=$(mktemp /tmp/spider.XXXX.tgz)
    if curl -fsSL --max-time 60 \
         "https://sourceforge.net/projects/dxspider/files/latest/download" -o "$TGZ" \
       && [[ -s "$TGZ" ]]; then
      runuser -u sysop -- mkdir -p "$SPIDER_DIR"
      tar -xzf "$TGZ" -C "$SPIDER_DIR" --strip-components=1
      chown -R sysop:sysop "$SPIDER_DIR"
      cloned=1
    fi
    rm -f "$TGZ"
  fi

  if [[ $cloned -eq 0 ]]; then
    msg_error "Impossible de récupérer DXSpider (réseau ? sources changées ?)"
    exit 1
  fi
  msg_ok "Source DXSpider installé dans $SPIDER_DIR"
fi

# DXSpider attend en dur `/spider` comme racine d'install. On crée un
# symlink vers /home/sysop/spider — c'est la convention historique.
if [[ ! -e /spider ]]; then
  ln -s "$SPIDER_DIR" /spider
  msg_ok "Symlink /spider → $SPIDER_DIR"
fi

# ── 5. premier lancement (création schéma SQLite, etc.) ──────────────
if [[ ! -f "$SPIDER_DIR/local/DXVars.pm" ]]; then
  msg_info "Bootstrap du schéma DXSpider (premier run)"
  runuser -u sysop -- bash -c "cd $SPIDER_DIR && yes | perl create_sysop.pl" >/dev/null 2>&1 || true
  msg_ok "Schéma initialisé"
fi

# ── 6. génération DXVars.pm ──────────────────────────────────────────
msg_info "Écriture de local/DXVars.pm"
mkdir -p "$SPIDER_DIR/local"
# Heredoc *quoté* ('EOF') = aucune interpolation shell ni Perl ; on
# substitue ensuite via sed pour insérer les valeurs avec quotes Perl
# correctes (évite que '@' dans un email soit pris pour un array Perl).
cat > "$SPIDER_DIR/local/DXVars.pm" <<'EOF'
# DXVars.pm — généré par dxspider-proxmox/install.sh
package main;
use strict;
use warnings;

our ($mycall, $myalias, $myname, $myemail,
     $mylatitude, $mylongitude,
     $myqth, $mylocator, $myregion, $mycity, $lang);

$mycall      = '__NODECALL__';
$myalias     = '__MYCALL__';
$myname      = '__MYNAME__';
$myemail     = '__MYEMAIL__';
$mylatitude  = __MYLAT__;
$mylongitude = __MYLON__;
$myqth       = '__MYQTH__';
$mylocator   = '__MYLOC__';
$myregion    = 'France';
$mycity      = '__MYQTH__';
$lang        = 'fr';

1;
EOF
# Substitution sécurisée : on échappe les apostrophes éventuelles dans
# les valeurs utilisateur pour ne pas casser les chaînes Perl single-quote.
esc() { printf '%s' "$1" | sed "s/'/\\\\'/g"; }
sed -i \
  -e "s|__NODECALL__|$(esc "$NODECALL")|" \
  -e "s|__MYCALL__|$(esc "$MYCALL")|" \
  -e "s|__MYNAME__|$(esc "$MYNAME")|" \
  -e "s|__MYEMAIL__|$(esc "$MYEMAIL")|" \
  -e "s|__MYLAT__|$MYLAT|" \
  -e "s|__MYLON__|$MYLON|" \
  -e "s|__MYQTH__|$(esc "$MYQTH")|g" \
  -e "s|__MYLOC__|$(esc "$MYLOC")|" \
  "$SPIDER_DIR/local/DXVars.pm"
chown sysop:sysop "$SPIDER_DIR/local/DXVars.pm"
msg_ok "DXVars.pm écrit"

# ── 7. fichier connect/ optionnel + startup ──────────────────────────
mkdir -p "$SPIDER_DIR/connect" "$SPIDER_DIR/scripts"
if [[ -n "$PEER1" ]]; then
  host="${PEER1%:*}" port="${PEER1#*:}"
  cat > "$SPIDER_DIR/connect/peer1" <<EOF
# Peer 1 — auto-générée par dxspider-proxmox/install.sh
# Adapte le call et les prompts selon ce que ton peer attend.
timeout 60
abort connect failed
abort already connected
abort timeout
connect telnet $host $port
'login: ' '$NODECALL'
EOF
  chown sysop:sysop "$SPIDER_DIR/connect/peer1"

  # startup script : DXSpider exécute /spider/scripts/startup au boot
  # avec privilèges sysop complets (les `connect`/`init` sont autorisés ici).
  printf "connect peer1\n" > "$SPIDER_DIR/scripts/startup"
  chown sysop:sysop "$SPIDER_DIR/scripts/startup"
  msg_ok "Peer 1 configuré ($PEER1) + startup script"
else
  # On crée un fichier startup vide pour que DXSpider ne se plaigne pas
  : > "$SPIDER_DIR/scripts/startup"
  chown sysop:sysop "$SPIDER_DIR/scripts/startup"
  msg_warn "Aucun peer configuré — node fonctionnel mais sans flux de spots."
fi

# ── 7b. Listeners.pm — force l'écoute publique sur 0.0.0.0:7300 ──────
# Sans ce fichier, DXSpider mojo n'écoute que sur 127.0.0.1 par défaut,
# ce qui rend le node inaccessible depuis le LAN.
msg_info "Configuration de l'écoute telnet (0.0.0.0:7300)"
cat > "$SPIDER_DIR/local/Listeners.pm" <<'EOF'
package main;
@main::listen = (
    ["0.0.0.0", 7300],
);
1;
EOF
chown sysop:sysop "$SPIDER_DIR/local/Listeners.pm"
msg_ok "Écoute :7300 forcée sur toutes interfaces"

# ── 7c. update_sysop.pl — assure priv=9 sur F4IOZ après DXVars ──────
msg_info "Mise à jour des privilèges sysop (priv=9)"
runuser -u sysop -- bash -c "cd $SPIDER_DIR && perl /spider/perl/update_sysop.pl" >/dev/null 2>&1 || true
msg_ok "Privilèges sysop appliqués"

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
WorkingDirectory=/spider/perl
Environment=LANG=en_US.UTF-8
Environment=LC_ALL=en_US.UTF-8
ExecStart=/usr/bin/perl /spider/perl/cluster.pl
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
if [[ -n "$PEER1" ]]; then
  echo -e "  ${BL}Peer    :${CL} $PEER1 (essai auto au boot via scripts/startup)"
else
  echo -e "  ${BL}Peer    :${CL} ${YW}aucun${CL} — voir 'À FAIRE' plus bas"
fi
echo -e "${GN}╠════════════════════════════════════════════════════════════╣${CL}"
echo -e "  ${BL}Logs    :${CL} journalctl -u dxspider -f"
echo -e "  ${BL}Debug   :${CL} tail -f /spider/local_data/debug/\$(date +%Y/%j).dat"
echo -e "  ${BL}Stop    :${CL} systemctl stop dxspider"
echo -e "  ${BL}Restart :${CL} systemctl restart dxspider"
echo -e "  ${BL}Config  :${CL} $SPIDER_DIR/local/DXVars.pm"
echo -e "  ${BL}Listen  :${CL} $SPIDER_DIR/local/Listeners.pm"
echo -e "  ${BL}Startup :${CL} $SPIDER_DIR/scripts/startup"
echo -e "${GN}╠════════════════════════════════════════════════════════════╣${CL}"
echo -e "  ${YW}À FAIRE${CL} pour recevoir le flux global de spots :"
echo -e "    1. Contacte un sysop ami (F5LEN, F6BEE, GB7DJK, etc.) pour"
echo -e "       autoriser ton node ${GN}$NODECALL${CL} comme peer."
echo -e "    2. Crée /spider/connect/<peerName> avec le script de connexion"
echo -e "       (login, prompts, etc. fournis par le sysop)."
echo -e "    3. Ajoute 'connect <peerName>' dans /spider/scripts/startup."
echo -e "    4. systemctl restart dxspider"
echo -e "${GN}╚════════════════════════════════════════════════════════════╝${CL}"
