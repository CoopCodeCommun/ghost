# Scripts de la stack

Quatre scripts, tous appelés par le `Makefile` — voir `make` à la racine.

| Script | Cible | Rôle |
|---|---|---|
| [`init_backup.sh`](./init_backup.sh) | `make init` | Configure la sauvegarde : clé SSH, dépôt BWH, `.env`, cron |
| [`backup_ghost.sh`](./backup_ghost.sh) | `make backup` | Dump MySQL + tout le dossier de la stack → borgwarehouse |
| [`check_backup.sh`](./check_backup.sh) | `make check` | Vérifie que la dernière sauvegarde est **restaurable** |
| [`update_ghost.sh`](./update_ghost.sh) | `make update` | Sauvegarde → `pull` → `up -d` → attente du healthcheck |

**Aucun script ne contient de secret.** Tous lisent le `.env` de la stack, que
git ignore. C'est la convention de la bibliothèque
[borgwarehouse](https://github.com/CoopCodeCommun/borgwarehouse), qui ne couvre
pas MySQL — d'où le script Ghost.

La mise en place et la vérification sont documentées dans le
[README racine](../README.md). Ce fichier-ci ne décrit que ce qui se passe sous
le capot.

## Ce que contient une archive

Le dump SQL est déposé dans `scripts/`, puis **tout le dossier de la stack** part
dans une seule archive : le dump, le `content/` (images, thèmes), le `.env` et le
`docker-compose.yml`. Une archive suffit à remonter le site de zéro, et tout y
est cohérent au même instant.

Quatre exclusions :

| Exclusion | Pourquoi |
|---|---|
| `db/` | Les fichiers InnoDB. Les copier à chaud donnerait une base corrompue — le dump SQL est la seule forme fiable. Ils sont de toute façon illisibles sans root. |
| `ghost/logs/` | Volumineux, sans valeur |
| `scripts/.ssh/` | La clé privée du dépôt : on ne met pas la clé du coffre dans le coffre |
| `.git/` | Déjà sur GitHub |

Le mot de passe root MySQL n'apparaît nulle part : il est lu **dans** le
conteneur au moment du `mysqldump`. En revanche le `.env` est archivé, donc la
passphrase du dépôt s'y trouve — sans conséquence, puisqu'il faut déjà cette
passphrase pour ouvrir l'archive qui la contient.

## Deux protections discrètes

**Un verrou** (`flock`) empêche deux sauvegardes simultanées. Sans lui, un
`make update` tombant pendant le cron partagerait le même dossier de dump : le
premier à finir le supprime pendant que l'autre archive encore, et on obtient une
archive **sans dump**, silencieusement.

**Le `prune` ne touche que les archives de cette stack** (`--glob-archives
"$PREFIX-*"`). Si deux instances Ghost partageaient un jour le même dépôt, sans
ce filtre elles se rogneraient mutuellement leur rétention, sans rien dire.

## Rétention

7 jours glissants, 30 quotidiennes, 12 hebdomadaires, puis **toutes** les
mensuelles et annuelles. C'est la politique en vigueur sur les autres dépôts
borgwarehouse.

## Cron

Posé par `make init`, dans le crontab de l'utilisateur (jamais écrasé : la ligne
n'est ajoutée que si elle n'existe pas). Il appelle le script directement, pas
`make` — ça éviterait une dépendance et un problème de répertoire courant pour
rien :

```cron
@daily bash /chemin/vers/la/stack/scripts/backup_ghost.sh >> $HOME/.ghost-backup-<prefix>.log 2>&1
```

Le log ne va **pas** dans `/var/log` : un utilisateur non-root ne peut pas y
écrire, et quand la redirection échoue, cron n'exécute même pas la commande — on
se retrouve sans sauvegarde *et* sans trace.

## Surveillance

Deux filets, complémentaires :

- **`make check`** dit si la dernière sauvegarde est restaurable.
- **borgwarehouse** envoie un mail si le dépôt ne reçoit plus rien (alerte réglée
  par `make init`). C'est le seul mécanisme qui prévient qu'une sauvegarde
  **n'est pas arrivée** — un cron qui échoue en silence, c'est un backup qui
  n'existe pas.

Chaque script contient par ailleurs un hook **Sentry** commenté en tête, pour
être alerté si le script lui-même échoue.
