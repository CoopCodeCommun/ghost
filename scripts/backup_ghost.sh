#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Sauvegarde d'une instance Ghost vers un depot borgwarehouse (BWH).
#
# Principe : mysqldump coherent depose dans le dossier de la stack, puis TOUT le
# dossier part dans UNE archive borg. L'archive contient donc le dump, le content
# (images, themes), le .env et le docker-compose.yml : tout ce qu'il faut pour
# remonter le site de zero, et le tout coherent au meme instant.
#
# Exclusions :
#   db/           fichiers InnoDB — les copier a chaud donnerait une base corrompue,
#                 le dump SQL est la seule forme fiable (et ils sont illisibles
#                 sans root de toute facon)
#   ghost/logs/   volumineux, sans valeur
#   scripts/.ssh/ la cle privee du depot : on ne l'archive pas dans le depot
#                 qu'elle protege. La garder au coffre (voir --init ci-dessous).
#   .git/         deja sur GitHub
#
# NB : ce script est lui-meme archive, avec sa BORG_PASSPHRASE en clair. C'est
# sans consequence : il faut deja cette passphrase pour ouvrir l'archive.
#
# 1- Ce script vit dans le dossier scripts/ de la stack Ghost, sur le serveur.
# 2- Choisir un PREFIX, puis generer une cle SSH DEDIEE a ce depot
#    (une cle = un depot sur borgwarehouse) :
#      mkdir -p ./.ssh && chmod 700 ./.ssh
#      ssh-keygen -t ed25519 -N '' -f ./.ssh/ghost_rtlx_ed25519      # nom = $PREFIX
# 3- Creer un depot dans borgwarehouse, y coller ./.ssh/ghost_rtlx_ed25519.pub
# 4- Renseigner les variables CHANGE ME ci-dessous.
# 5- Initier le depot :   ./backup_ghost.sh --init
# 6- Sauvegarder :        ./backup_ghost.sh
# 7- Cron (a lancer par un utilisateur membre du groupe docker, ou root) :
#      @daily bash /opt/ghost/scripts/backup_ghost.sh >> /var/log/backup_ghost.log 2>&1
#
# Le mot de passe root MySQL n'est PAS recopie ici : il est lu dans le conteneur.
#####

## Surveillance optionnelle via Sentry :
## Installez : curl -sL https://sentry.io/get-cli/ | bash   (maj : sentry-cli update)
# export SENTRY_DSN=''
# eval "$(sentry-cli bash-hook)"


SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

# Dossier de la stack Ghost (celui qui contient docker-compose.yml et .env).
# Par defaut : le dossier parent de scripts/.
GHOST_DIR="${GHOST_DIR:-$(dirname "$SCRIPT_DIR")}"
COMPOSE_FILE="$GHOST_DIR/docker-compose.yml"
CONTENT_DIR="$GHOST_DIR/ghost"

# CHANGE ME : nom affiche au debut de chaque archive. ex : ghost_rtlx
PREFIX=""

# CHANGE ME : adresse du depot, identique a celle de la creation du depot borg
# ex : ssh://borgwarehouse@localhost:2226/./674b31c6
export BORG_REPO=""

# CHANGE ME : passphrase generee lors de la creation du depot borg
export BORG_PASSPHRASE=""

# Cle SSH DEDIEE a ce depot (une cle = un depot sur borgwarehouse).
SSH_KEY="$SCRIPT_DIR/.ssh/${PREFIX}_ed25519"

# Dossier de travail pour le dump (supprime apres l'archivage)
DUMP_DIR="${DUMP_DIR:-$SCRIPT_DIR/mysql-dump-$PREFIX}"


#### PREPARATION ####
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes

: "${BORG_REPO:?BORG_REPO doit etre renseigne (CHANGE ME)}"
: "${PREFIX:?PREFIX doit etre renseigne (CHANGE ME)}"
command -v borg   >/dev/null || { echo "[ghost-borg] borg introuvable dans le PATH" >&2; exit 1; }
command -v docker >/dev/null || { echo "[ghost-borg] docker introuvable dans le PATH" >&2; exit 1; }
[ -f "$COMPOSE_FILE" ] || { echo "[ghost-borg] compose introuvable : $COMPOSE_FILE" >&2; exit 1; }

DATE_NOW=$(date +%Y-%m-%d-%H-%M)

# Force l'usage de CETTE cle (et pas une autre de l'agent SSH).
if [ -f "$SSH_KEY" ]; then
  chmod 600 "$SSH_KEY" 2>/dev/null || true
  export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i $SSH_KEY"
else
  echo "[ghost-borg] [INFO] aucune cle a $SSH_KEY — SSH utilisera la config systeme." >&2
fi

# Mode init : initialise le depot puis sort.
if [ "${1:-}" = "--init" ]; then
  echo "$DATE_NOW initialisation du depot borg ($BORG_REPO) avec repokey-blake2"
  /usr/bin/borg init -e repokey-blake2 "$BORG_REPO"
  exit 0
fi

[ -d "$CONTENT_DIR" ] || { echo "[ghost-borg] dossier content introuvable : $CONTENT_DIR" >&2; exit 1; }


#### DUMP MYSQL ####
# Nettoyage garanti du dump meme en cas d'erreur.
trap 'rm -rf "$DUMP_DIR"' EXIT
rm -rf "$DUMP_DIR"
mkdir -p "$DUMP_DIR"
DUMP_FILE="$DUMP_DIR/ghost.sql"

echo "$DATE_NOW dump de la base 'ghost' (mysqldump, transaction unique)"
# --single-transaction : dump coherent sans verrouiller le site (InnoDB).
# Le mot de passe root est lu DANS le conteneur, il ne transite pas par ce script.
docker compose -f "$COMPOSE_FILE" exec -T ghost-mysql \
  sh -c 'exec mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" \
      --single-transaction --quick --routines --triggers ghost' \
  > "$DUMP_FILE"

# Garde-fou : un dump vide = on n'archive pas.
if [ ! -s "$DUMP_FILE" ]; then
  echo "[ghost-borg] dump vide ($DUMP_FILE) — abandon" >&2
  exit 1
fi


#### BORG CREATE ####
# On archive TOUT le dossier de la stack : le dump (depose dans scripts/), le
# content, mais aussi le .env et le docker-compose.yml. Une archive contient
# ainsi tout ce qu'il faut pour remonter le site de zero.
echo "$DATE_NOW on cree l'archive borg (dossier complet de la stack)"
/usr/bin/borg create -vs --compression lz4 \
  --exclude "$GHOST_DIR/db" \
  --exclude "$GHOST_DIR/ghost/logs" \
  --exclude "$GHOST_DIR/scripts/.ssh" \
  --exclude "$GHOST_DIR/.git" \
  "$BORG_REPO::$PREFIX-$DATE_NOW" \
  "$GHOST_DIR"

echo "$DATE_NOW on prune les vieux borg :"
/usr/bin/borg prune -v --list \
  --keep-within=7d --keep-daily=30 --keep-weekly=12 --keep-monthly=-1 --keep-yearly=-1 \
  "$BORG_REPO"

echo "$DATE_NOW termine"
