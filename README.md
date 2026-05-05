# DXSpider — Proxmox CT installer

Déploiement automatique d'un node DX-cluster (DXSpider) dans un conteneur LXC
sur Proxmox VE.

## Installation en une ligne

Sur l'hôte Proxmox :

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/f4ioz/dxspider-proxmox/main/ct.sh)
```

Le script :

1. Demande l'ID du CT, hostname, storage, RAM/CPU/disk, réseau.
2. Télécharge le template Debian 13 (sinon 12) si absent.
3. Crée et démarre le CT (unprivileged, nesting ON).
4. À l'intérieur du CT, exécute `install.sh` qui :
   - active les locales `en_US.UTF-8` / `fr_FR.UTF-8`
   - installe les dépendances Perl + outils (cpanm, build-essential, openssh-server, telnet…)
   - installe les modules Perl additionnels via cpanm si manquants en apt (notamment `Digest::SHA1` qui n'a plus de paquet Debian 13)
   - active SSH (root + password)
   - clone DXSpider (cascade : github mirror → official → SourceForge tarball)
   - crée le symlink `/spider` → `/home/sysop/spider`
   - demande **callsign, locator, QTH, peer (optionnel)**
   - convertit le locator → lat/lon Maidenhead
   - génère `local/DXVars.pm` et `local/Listeners.pm` (écoute `0.0.0.0:7300`)
   - met à jour les privilèges sysop (priv=9) via `update_sysop.pl`
   - installe et démarre le service systemd `dxspider`
5. Affiche IP + port telnet (`telnet <IP> 7300`) + procédure pour ajouter un peer.

> **À propos des peers** : DXSpider mojo bloque les commandes sysop (`init`, `connect`)
> depuis telnet pour des raisons de sécurité. Le seul moyen de connecter un peer est :
> - via `/spider/scripts/startup` (exécuté au boot avec privilèges complets), ou
> - via la console locale (`/spider/perl/console.pl`).
>
> De plus, les nodes publics comme GB7DJK refusent les connexions de nodes inconnus —
> il faut une autorisation préalable du sysop côté distant. Pour démarrer rapidement,
> demande peering à un sysop ami (F5LEN, F6BEE…).

## Resources par défaut

| Param  | Default         |
|--------|-----------------|
| CPU    | 1 core          |
| RAM    | 512 Mo          |
| Disk   | 4 Go            |
| OS     | Debian 12       |
| Privé  | unprivileged    |
| Réseau | DHCP par défaut |

DXSpider est très léger ; ces valeurs suffisent pour un node personnel.

## Connexion

Depuis un client telnet (ou `nc`) :

```bash
telnet <IP-du-CT> 7300
# login = ton indicatif (ex: F4IOZ)
```

Commandes utiles une fois loggé :

| Commande         | Effet                                           |
|------------------|-------------------------------------------------|
| `set/dx`         | reçoit les spots DX                             |
| `set/skim`       | reçoit aussi les spots RBN/Skimmer              |
| `sh/dx 25`       | dernier 25 spots                                |
| `sh/dx 50 by F`  | 50 derniers spots français                      |
| `sh/dx 20 14`    | 20 derniers spots sur 14 MHz                    |
| `dx 14074 EA1ABC FT8 first contact` | spotter un DX                |
| `bye`            | quitter                                          |

Côté sysop (au moins une fois après install) :

```
set/sys                     # entre en mode sysop (avec le node-call)
create/node F4IOZ-1
init peer1
init peer2
init peer3
sh/cluster                  # liste des nodes connectés
```

## Intégration au site F4IOZ

Une fois le CT en route, l'app FastAPI du site peut s'y connecter via telnet
persistant et exposer les spots en JSON / WebSocket. Voir `app/dx_local.py`
(à venir) qui remplacera la source PSKReporter pour `/dx`.

Configuration côté `config.yml` :

```yaml
dxcluster:
  host: 192.168.1.50
  port: 7300
  login: F4IOZ-RDR    # un indicatif read-only dédié
```

## Désinstallation / reset

Sur l'hôte Proxmox :

```bash
pct stop <CTID>
pct destroy <CTID>
```

## Sources

- DXSpider : https://www.dxcluster.org/
- Doc utilisateurs : https://www.dxcluster.org/main/usermanual_en-3.html
- Doc sysop : https://www.dxcluster.org/main/sysopmanual_en-3.html
