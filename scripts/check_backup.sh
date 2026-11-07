#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Verifie que la derniere sauvegarde est REELLEMENT restaurable, sans rien
# restaurer. Lance par :  make check
#
# Trois questions, dans l'ordre :
#   1. Une archive recente existe-t-elle ? (sinon : le cron est mort)
#   2. Contient-elle le dump, le content et le .env ?
#   3. Le dump est-il exploitable — et COMPLET ?
#
# Le point 3 est celui qui compte. Un dump tronque (disque plein, timeout,
# conteneur tue en plein dump) produit un fichier de bonne taille, present dans
# l'archive, et parfaitement inutilisable. mysqldump termine ses dumps par
# "-- Dump completed" : c'est notre preuve de non-troncature.
#
# Sort en code non nul si quoi que ce soit cloche : utilisable en monitoring.
#####

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
GHOST_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$GHOST_DIR/.env"

# Age maximum tolere pour la derniere archive. 25 h = la sauvegarde quotidienne
# d'hier, plus une heure de marge. C'est aussi le reglage de l'alerte BWH.
AGE_MAX_HEURES="${AGE_MAX_HEURES:-25}"

ok()      { echo "  [ok]   $*"; }
ko()      { echo "  [KO]   $*" >&2; ERREURS=$((ERREURS + 1)); }
erreur()  { echo "[check] ERREUR : $*" >&2; exit 2; }
ERREURS=0

[ -f "$ENV_FILE" ] || erreur ".env introuvable : $ENV_FILE"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${BORG_PREFIX:?BORG_PREFIX absent du .env — la sauvegarde n'est pas configuree (make init)}"
: "${BORG_REPO:?BORG_REPO absent du .env — la sauvegarde n'est pas configuree (make init)}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE absent du .env}"
command -v borg >/dev/null || erreur "borg introuvable dans le PATH."

SSH_KEY="$SCRIPT_DIR/.ssh/${BORG_PREFIX}_ed25519"
[ -f "$SSH_KEY" ] && export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i $SSH_KEY"

echo "[check] depot : $BORG_REPO"
echo


#### 1. UNE ARCHIVE RECENTE EXISTE-T-ELLE ? ####
echo "1. Fraicheur"

# --glob-archives : on ne regarde QUE les archives de cette stack. Sans ce
# filtre, une autre instance partageant le depot suffirait a nous rassurer.
DERNIERE="$(borg list --glob-archives "$BORG_PREFIX-*" --last 1 \
  --format '{archive}{TAB}{time:%Y-%m-%d %H:%M:%S}{NL}' "$BORG_REPO")"
[ -n "$DERNIERE" ] || erreur "aucune archive '$BORG_PREFIX-*' dans le depot. La sauvegarde n'a jamais tourne."

ARCHIVE="${DERNIERE%%	*}"
DATE_ARCHIVE="${DERNIERE#*	}"

AGE_SECONDES=$(( $(date +%s) - $(date -d "$DATE_ARCHIVE" +%s) ))
AGE_HEURES=$(( AGE_SECONDES / 3600 ))

if [ "$AGE_HEURES" -le "$AGE_MAX_HEURES" ]; then
  ok "derniere archive : $ARCHIVE (il y a ${AGE_HEURES} h)"
else
  ko "derniere archive : $ARCHIVE — ${AGE_HEURES} h, soit plus de ${AGE_MAX_HEURES} h."
  ko "le cron ne tourne plus. Verifie : crontab -l"
fi


#### 2. L'ARCHIVE CONTIENT-ELLE CE QU'IL FAUT ? ####
echo
echo "2. Contenu de l'archive"

CONTENU="$(borg list --format '{path}{NL}' "$BORG_REPO::$ARCHIVE")"

CHEMIN_DUMP="$(printf '%s\n' "$CONTENU" | grep -E '/mysql-dump-[^/]+/ghost\.sql$' | head -n1 || true)"
if [ -n "$CHEMIN_DUMP" ]; then
  ok "dump SQL present : ${CHEMIN_DUMP##*/}"
else
  ko "aucun dump SQL dans l'archive."
fi

if grep -qE '/ghost/(images|themes|settings)(/|$)' <<< "$CONTENU"; then
  ok "content Ghost present (images / themes / settings)"
else
  ko "le content de Ghost est absent de l'archive."
fi

if grep -qE '/\.env$' <<< "$CONTENU"; then
  ok ".env present (la stack est remontable telle quelle)"
else
  ko ".env absent : une restauration demanderait de resaisir les secrets."
fi


#### 3. LE DUMP EST-IL EXPLOITABLE, ET COMPLET ? ####
echo
echo "3. Le dump est-il restaurable ?"

if [ -z "$CHEMIN_DUMP" ]; then
  ko "pas de dump a verifier."
else
  # On lit tout le flux (pas de head/grep -q qui fermerait le tuyau : borg
  # recevrait un SIGPIPE, et pipefail ferait echouer le script a tort).
  # Une seule passe awk, rien n'est ecrit sur le disque.
  VERDICT="$(borg extract --stdout "$BORG_REPO::$ARCHIVE" "$CHEMIN_DUMP" | awk '
    /CREATE TABLE `posts`/  { posts = 1 }
    /CREATE TABLE `users`/  { users = 1 }
    /^-- Dump completed/    { complet = 1 }
    END { printf "%d %d %d", posts + 0, users + 0, complet + 0 }
  ')"
  read -r A_POSTS A_USERS COMPLET <<< "$VERDICT"

  if [ "$A_POSTS" = 1 ] && [ "$A_USERS" = 1 ]; then
    ok "schema Ghost retrouve (tables posts et users)"
  else
    ko "le dump ne contient pas le schema Ghost attendu."
  fi

  if [ "$COMPLET" = 1 ]; then
    ok "dump complet (mysqldump est alle au bout)"
  else
    ko "dump TRONQUE : pas de '-- Dump completed' en fin de fichier."
    ko "cette sauvegarde n'est pas restaurable."
  fi
fi


#### VERDICT ####
echo
if [ "$ERREURS" -eq 0 ]; then
  echo "[check] La derniere sauvegarde est restaurable."
  exit 0
fi
echo "[check] $ERREURS probleme(s). Cette sauvegarde n'est pas fiable." >&2
exit 1
