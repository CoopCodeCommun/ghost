#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Mise a jour de la stack Ghost, avec sauvegarde prealable.
#
#   sauvegarde borg  ->  docker compose pull  ->  up -d  ->  attente du healthcheck
#
# Au premier demarrage d'une nouvelle version, Ghost joue ses migrations de
# schema : elles ne sont PAS reversibles. D'ou la sauvegarde avant le pull.
#
# Usage :
#   ./update_ghost.sh              # backup puis mise a jour
#   ./update_ghost.sh --no-backup  # mise a jour seule (a eviter)
#
# Prerequis : backup_ghost.sh configure (voir son en-tete).
#####

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
GHOST_DIR="${GHOST_DIR:-$(dirname "$SCRIPT_DIR")}"
COMPOSE_FILE="$GHOST_DIR/docker-compose.yml"

# Duree max d'attente du retour au vert de Ghost, en secondes.
# Un saut de plusieurs versions peut enchainer des migrations pendant 10-15 min
# (762 s pour 6.52 -> 6.75 le 2026-11-08). Surchargeable : HEALTH_TIMEOUT=1800 make update
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-900}"

[ -f "$COMPOSE_FILE" ] || { echo "[ghost-update] compose introuvable : $COMPOSE_FILE" >&2; exit 1; }

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }


#### 1. SAUVEGARDE ####
if [ "${1:-}" = "--no-backup" ]; then
  echo "[ghost-update] sauvegarde IGNOREE (--no-backup)"
else
  echo "[ghost-update] sauvegarde avant mise a jour..."
  bash "$SCRIPT_DIR/backup_ghost.sh"
fi


#### 2. MISE A JOUR ####
VERSION_AVANT="$(compose exec -T ghost sh -c 'cat current/package.json' 2>/dev/null \
  | grep -m1 '"version"' | cut -d'"' -f4 || echo 'inconnue')"
echo "[ghost-update] version actuelle : $VERSION_AVANT"

echo "[ghost-update] recuperation des images..."
compose pull

echo "[ghost-update] redemarrage de la stack..."
compose up -d


#### 3. VERIFICATION ####
echo "[ghost-update] attente du healthcheck Ghost (max ${HEALTH_TIMEOUT}s)..."
# On resout l'ID du conteneur via compose : son nom depend du COMPOSE_PROJECT_NAME
# de cette instance, plusieurs Ghost pouvant tourner sur le meme serveur.
CONTENEUR="$(compose ps -q ghost)"
[ -n "$CONTENEUR" ] || { echo "[ghost-update] conteneur ghost introuvable" >&2; exit 1; }

ATTENTE=0
while [ "$ATTENTE" -lt "$HEALTH_TIMEOUT" ]; do
  ETAT="$(docker inspect --format '{{.State.Health.Status}}' "$CONTENEUR" 2>/dev/null || echo 'absent')"
  case "$ETAT" in
    healthy)
      VERSION_APRES="$(compose exec -T ghost sh -c 'cat current/package.json' 2>/dev/null \
        | grep -m1 '"version"' | cut -d'"' -f4 || echo 'inconnue')"
      echo "[ghost-update] OK — Ghost est en bonne sante."
      echo "[ghost-update] $VERSION_AVANT -> $VERSION_APRES"
      exit 0
      ;;
    unhealthy)
      # Pas d'abandon ici : pendant les migrations, Ghost ne repond pas et le
      # healthcheck le declare unhealthy (~6 min) alors qu'il travaille encore.
      # On n'abandonne que si le conteneur s'arrete ou redemarre en boucle.
      [ "$(docker inspect --format '{{.State.Running}} {{.RestartCount}}' "$CONTENEUR" 2>/dev/null)" = "true 0" ] \
        || break
      ;;
  esac
  sleep 5
  ATTENTE=$((ATTENTE + 5))
done

echo "[ghost-update] ECHEC : Ghost n'est pas revenu en bonne sante (etat : ${ETAT:-inconnu})." >&2
echo "[ghost-update] Derniers logs :" >&2
compose logs --tail 50 ghost >&2 || true
echo "[ghost-update] Si les logs montrent encore des migrations (INFO Adding/Removing...), Ghost travaille :" >&2
echo "[ghost-update]   NE PAS redemarrer ni restaurer ; suivre : docker compose logs -f ghost" >&2
echo "[ghost-update] Sauvegarde disponible dans borgwarehouse." >&2
echo "[ghost-update] Procedure de restauration : voir la section 'Restauration' du README." >&2
exit 1
