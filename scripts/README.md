# Scripts de sauvegarde et de mise à jour

Deux scripts, à configurer une fois sur le serveur de production.

| Script | Rôle |
|---|---|
| [`backup_ghost.sh`](./backup_ghost.sh) | Dump MySQL + dossier `content/` → dépôt borgwarehouse |
| [`update_ghost.sh`](./update_ghost.sh) | Sauvegarde → `pull` → `up -d` → attente du healthcheck |

Ils suivent les conventions de la bibliothèque
[borgwarehouse](https://github.com/CoopCodeCommun/borgwarehouse) (style
« CHANGE ME », clé SSH dédiée, mode `--init`, politique de prune identique), qui
ne couvre pas MySQL — d'où ce script-ci.

## Configuration du backup (une seule fois)

```bash
cd /opt/ghost/scripts

# 1. Générer une clé SSH dédiée à ce dépôt (une clé = un dépôt sur BWH)
mkdir -p ./.ssh && chmod 700 ./.ssh
ssh-keygen -t ed25519 -N '' -f ./.ssh/ghost_rtlx_ed25519
cat ./.ssh/ghost_rtlx_ed25519.pub     # -> à coller dans le nouveau dépôt sur BWH

# 2. Créer le dépôt sur l'interface borgwarehouse, y coller la clé publique,
#    puis copier l'adresse SSH du dépôt.

# 3. Renseigner les variables CHANGE ME en tête de backup_ghost.sh :
#    PREFIX (= le nom de la clé, ici ghost_rtlx), BORG_REPO, BORG_PASSPHRASE
#    La passphrase doit être stockée dans un coffre-fort numérique.

# 4. Initialiser le dépôt
./backup_ghost.sh --init

# 5. Première sauvegarde, puis vérifier qu'elle apparaît sur BWH
./backup_ghost.sh
```

Le mot de passe root MySQL n'est **pas** recopié dans le script : il est lu à
l'intérieur du conteneur au moment du `mysqldump`.

## Cron

À lancer par `root` ou par un utilisateur membre du groupe `docker` :

```cron
@daily bash /opt/ghost/scripts/backup_ghost.sh >> /var/log/backup_ghost.log 2>&1
```

Rétention côté borg : 7 jours glissants, 30 quotidiennes, 12 hebdomadaires, puis
mensuelles et annuelles conservées indéfiniment.

Borgwarehouse envoie un mail si un dépôt dépasse son intervalle attendu : c'est
le filet qui prévient qu'une sauvegarde n'est pas arrivée. Penser à régler cet
intervalle sur le dépôt (24 h + marge).

## Mise à jour

```bash
/opt/ghost/scripts/update_ghost.sh
```

La sauvegarde est jouée avant le `pull`. C'est le point important : au premier
démarrage d'une nouvelle version, Ghost applique ses migrations de schéma, et
elles ne sont pas réversibles. Si le healthcheck ne repasse pas au vert, le
script affiche les logs et sort en erreur — la marche à suivre est dans la
section « Restauration » du [README racine](../README.md).

L'image est épinglée sur `ghost:6-alpine` : les correctifs et versions mineures
arrivent au `pull`, mais jamais une majeure par surprise. Le passage à Ghost 7,
le jour venu, sera un changement explicite du `docker-compose.yml`.

## Surveillance optionnelle

Chaque script contient un hook **Sentry** commenté en tête, pour être alerté si
le script lui-même échoue.
