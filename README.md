# Ghost — dossier de mise en production

Stack Ghost 6 + MySQL 8, derrière un Traefik existant, avec sauvegarde
borgwarehouse et script de mise à jour.

## Prérequis sur le serveur

- Docker et le plugin `compose`.
- Un Traefik déjà en place, avec un réseau Docker externe nommé `frontend` et un
  certresolver nommé `myresolver`. (Si tes noms diffèrent, adapte les `labels`
  et le bloc `networks` du `docker-compose.yml`.)
- Un enregistrement DNS A pointant le domaine du blog vers le serveur.
- Un compte SMTP (voir plus bas — ce n'est pas optionnel).
- `borg` installé sur l'hôte, et un serveur borgwarehouse joignable.

## Installation

```bash
git clone https://github.com/CoopCodeCommun/ghost /opt/ghost
cd /opt/ghost

# Copier l'exemple et remplir TOUTES les variables
cp env_example .env
openssl rand -hex 32        # pour MYSQL_ROOT_PASSWORD
openssl rand -hex 32        # pour MYSQL_PASSWORD
nano .env

# Lancer
docker compose up -d && docker compose logs -f ghost
```

Puis se rendre sur `https://<DOMAIN>/ghost/` pour créer le compte propriétaire.
**Faire cette étape tout de suite** : tant que le compte n'existe pas, n'importe
qui arrivant sur cette URL peut le créer.

Vérifier que tout est vert :

```bash
docker compose ps        # les deux conteneurs doivent être "healthy"
```

## Configuration

Toute la configuration passe par le fichier `.env`, lu par le
`docker-compose.yml` qui la transmet à Ghost sous forme de variables
d'environnement (`url`, `database__*`, `mail__*`). C'est la méthode de référence
de Ghost 6 : il n'y a **pas** de `config.production.json` dans cette stack.

Après toute modification du `.env`, recréer le conteneur concerné :

```bash
docker compose up -d
```

### Base de données

`MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD` et `MYSQL_USER` **ne doivent plus jamais
changer une fois la base initialisée** : ça modifierait la configuration de
connexion sans modifier ce que la base attend réellement, et Ghost ne pourrait
plus s'y connecter.

MySQL 8 est la seule base supportée par Ghost en production.

### SMTP — obligatoire

Ghost envoie par SMTP les emails transactionnels : connexion du staff,
invitations, réinitialisation de mot de passe. Sans SMTP fonctionnel, **tu ne
peux plus te reconnecter à l'admin si tu perds ta session**. Ce n'est pas le
même canal que l'envoi des newsletters en masse.

Les variables `MAIL_*` du `.env` couvrent le cas courant (SMTP authentifié en
TLS implicite, port 465). Pour un serveur en STARTTLS, mettre `MAIL_PORT=587` et
`MAIL_SECURE=false`.

### Newsletters : un second système, séparé

Ghost a **deux canaux d'email qui n'ont rien à voir**, et c'est une source de
confusion classique :

| | Transactionnel | Newsletters (bulk) |
|---|---|---|
| Sert à | Connexions staff, invitations, resets, magic links | Envoyer un article à tous les abonnés |
| Canal | SMTP, n'importe quel fournisseur | API **Mailgun uniquement** |
| Réglé dans | `.env` (`MAIL_*`) | L'admin Ghost, ou `.env` (`MAILGUN_*`) |

Le SMTP envoie un mail à la fois. Une newsletter, c'est un envoi de masse : le
faire en SMTP classique ferait blacklister l'IP du serveur en quelques heures.
Ghost délègue donc ça à une API qui gère la réputation d'envoi, les bounces et
les plaintes spam — et [la seule supportée est
Mailgun](https://docs.ghost.org/faq/mailgun-newsletters).

**Le SMTP est obligatoire, Mailgun ne l'est pas.** Un site sans newsletter n'a
pas besoin de Mailgun. Rien n'empêche par ailleurs d'utiliser Mailgun pour les
deux, via son SMTP : ça reste deux réglages distincts, avec un seul fournisseur.

## Plusieurs Ghost sur le même serveur

C'est prévu : rien n'est nommé en dur dans la stack. Chaque instance est un clone
du dépôt dans son propre dossier, avec son `.env`.

```bash
git clone https://github.com/CoopCodeCommun/ghost /opt/ghost-lecafe
cd /opt/ghost-lecafe
cp env_example .env
```

Deux variables doivent différer d'une instance à l'autre :

| Variable | Rôle |
|---|---|
| `COMPOSE_PROJECT_NAME` | Unique sur le serveur. Nomme les conteneurs, le réseau privé et les routers Traefik. |
| `DOMAIN` | Le domaine du blog, forcément différent. |

Les mots de passe MySQL, eux, sont **propres à chaque instance** : chaque stack a
sa base, dans son propre dossier `./db`. Ne pas les recopier d'une instance à
l'autre.

Le reste s'isole tout seul : les conteneurs sont nommés d'après le projet, le
réseau `backend` est préfixé par Docker, et les dossiers `ghost/` et `db/` sont
relatifs au dossier de la stack. Seul le réseau `frontend` est partagé, ce qui
est justement le but — c'est par là que Traefik les atteint.

Côté sauvegarde, chaque instance a **son propre dépôt borgwarehouse et sa propre
clé SSH** (une clé = un dépôt). Il suffit d'un `PREFIX` distinct dans chaque
`scripts/backup_ghost.sh`.

## Sauvegarde

`scripts/backup_ghost.sh` dépose un dump MySQL dans le dossier de la stack, puis
pousse **tout le dossier** dans une archive borg unique : le dump, le `content/`
(images, thèmes), le `.env` et le `docker-compose.yml`. Une archive suffit donc à
remonter le site de zéro. Détails et exclusions dans
[`scripts/README.md`](./scripts/README.md).

Les données vivent dans deux dossiers créés par Docker au premier démarrage :

| Dossier | Contenu | Sauvegardé ? |
|---|---|---|
| `./ghost/` | Images, thèmes, paramètres (`content/` de Ghost) | Oui, tel quel |
| `./db/` | Fichiers InnoDB de MySQL | Non — remplacé par le dump SQL |

### Mise en place : `make init`

Une seule commande configure toute la sauvegarde vers le borgwarehouse de Code
Commun (<https://borgwarehouse.codecommun.coop/>, SSH sur le port **2226**) :

```bash
command -v borg || sudo apt install borgbackup
make init
```

Elle enchaîne : génération de la clé SSH dédiée (sur borgwarehouse, **une clé =
un dépôt**), création du dépôt via l'API, tirage d'une passphrase, `borg init`,
export de la clé, pose du cron, première sauvegarde et vérification.

Deux choses te seront demandées :

**Un token API borgwarehouse** (*Account → Integrations*), qui permet de créer le
dépôt automatiquement. Génère-le avec la **permission `create` uniquement** :
c'est le seul appel que fait `make init` (`POST /api/v1/repositories`), tout le
reste — `init`, `create`, `prune`, `list` — passant par SSH avec la clé dédiée.
Un token *create-only* qui fuiterait ne permettrait ni de lister ni de supprimer
tes dépôts, au pire d'en créer des parasites.

Le token n'est de toute façon **jamais stocké** : il est saisi au clavier, et ne
sert qu'une fois. Sans token, `make init` affiche la clé publique et te laisse
créer le dépôt à la main dans l'interface, puis coller son adresse.

**De confirmer que tu as mis la passphrase au coffre.** Le script affiche la
passphrase, la clé exportée et l'adresse du dépôt, puis attend un `OUI`. Ce n'est
pas une formalité : sans ces éléments, les archives sont un bloc chiffré
définitivement illisible. C'est le seul maillon que la sauvegarde ne peut pas se
sauvegarder elle-même. **Coffre-fort numérique, tout de suite.**

`make init` est **rejouable**. Si l'API est injoignable, si `borg init` échoue ou
si tu fais Ctrl-C en plein milieu, relance-le : il reprend ce qui existe déjà. Le
seul cas où il refuse de continuer, c'est quand le dépôt **contient déjà des
archives** — car régénérer une passphrase les rendrait illisibles.

### Vérifier que la sauvegarde vaut quelque chose : `make check`

```bash
make check
```

Il répond à la seule question qui compte — *est-ce restaurable ?* — sans rien
restaurer :

1. **Fraîcheur** : la dernière archive de cette stack date de moins de 25 h.
   Sinon, le cron est mort et personne ne l'avait remarqué.
2. **Contenu** : l'archive contient bien le dump SQL, le `content/` et le `.env`.
3. **Le dump est-il exploitable** : le dump est extrait en streaming (rien n'est
   écrit sur le disque) et on y cherche le schéma de Ghost **et** le marqueur
   `-- Dump completed` que `mysqldump` écrit en dernier. Un dump tronqué — disque
   plein, conteneur tué en plein vol — a la bonne taille, se trouve bien dans
   l'archive, et n'est pas restaurable. C'est précisément ce que ce test attrape.

Sortie en code non nul si quoi que ce soit cloche : utilisable tel quel dans un
monitoring.

**Ce que `make check` ne teste pas** : ta copie de coffre-fort. Il vérifie le
dépôt avec le `.env` de la machine, pas avec la passphrase que tu as archivée
ailleurs — or c'est celle-là, et elle seule, qui servira le jour où le serveur
aura brûlé. Vérifie une fois, depuis une autre machine, qu'un `borg list` passe
avec les éléments du coffre.

### La surveillance ne vient pas d'ici

C'est **borgwarehouse** qui t'enverra un mail si le dépôt ne reçoit plus rien
(alerte réglée par `make init` sur 25 h pour une sauvegarde quotidienne). Un cron
qui échoue en silence, c'est un backup qui n'existe pas : `make check` te dit que
la dernière sauvegarde est bonne, l'alerte BWH te prévient qu'il n'y en a plus.

### Rétention

Le `prune` conserve 7 jours glissants, 30 sauvegardes quotidiennes, 12
hebdomadaires, puis **toutes** les mensuelles et annuelles.

## Mise à jour

`scripts/update_ghost.sh` rejoue la sauvegarde avant chaque `docker compose
pull`, puis attend que Ghost repasse au vert. Voir
[`scripts/README.md`](./scripts/README.md).

## Restauration

Une archive contient **tout le dossier de la stack** : le dump SQL, le `content/`
(images, thèmes), le `.env` et le `docker-compose.yml`. Il n'y a donc rien à
reconstruire à la main.

### Repartir de zéro (le serveur a brûlé)

```bash
# Sur la nouvelle machine, avec borg installé.
# La clé SSH du dépôt n'est PAS dans l'archive (voir plus bas) : en générer une
# nouvelle et l'ajouter au dépôt depuis l'interface borgwarehouse.
ssh-keygen -t ed25519 -N '' -f ~/.ssh/ghost_restore_ed25519
cat ~/.ssh/ghost_restore_ed25519.pub     # → à ajouter au dépôt sur BWH

export BORG_REPO='ssh://borgwarehouse@…/./xxxxxxxx'
export BORG_PASSPHRASE='…'               # depuis le coffre-fort
export BORG_RSH="ssh -i ~/.ssh/ghost_restore_ed25519 -oIdentitiesOnly=yes"

borg list                                # choisir l'archive
borg extract --list "$BORG_REPO::<archive>"
# L'extraction recrée l'arborescence absolue d'origine, sans le / initial :
#   home/jonas/…/upop_ghost/            <- le dossier complet, .env compris

cd home/jonas/…/upop_ghost/              # ou déplacer le dossier où on veut

# La base repart vide (db/ n'est pas sauvegardé), puis on y injecte le dump.
docker compose up -d ghost-mysql
docker compose exec -T ghost-mysql \
  sh -c 'exec mysql -u root -p"$MYSQL_ROOT_PASSWORD" ghost' \
  < scripts/mysql-dump-<prefix>/ghost.sql

docker compose up -d
docker compose logs -f ghost
```

### Restaurer une instance qui tourne encore

```bash
cd ~/tank/Gits/upop_ghost
docker compose stop ghost                # on laisse MySQL debout

borg extract --list "$BORG_REPO::<archive>"   # extrait dans le dossier courant
rsync -a --delete <chemin-extrait>/ghost/ ./ghost/

docker compose exec -T ghost-mysql \
  sh -c 'exec mysql -u root -p"$MYSQL_ROOT_PASSWORD" ghost' \
  < <chemin-extrait>/scripts/mysql-dump-<prefix>/ghost.sql

docker compose up -d
```

### Après une mise à jour ratée

Remettre aussi le `docker-compose.yml` sur la version d'image précédente **avant**
de redémarrer. Ghost joue ses migrations de schéma au premier démarrage d'une
nouvelle version, et elles ne sont pas réversibles : un Ghost récent sur une base
restaurée d'une version antérieure la migrera à nouveau, et un Ghost ancien
refuse de démarrer sur un schéma trop récent.

### Ce qui n'est pas dans l'archive

La **clé SSH du dépôt** (`scripts/.ssh/`) : on ne met pas la clé du coffre dans le
coffre. En cas de perte totale, on en génère une nouvelle et on l'ajoute au dépôt
depuis l'interface borgwarehouse.

Doivent donc vivre **dans un coffre-fort numérique**, sans quoi la sauvegarde est
irrécupérable :

- la **passphrase** du dépôt borg,
- la **clé du dépôt** exportée (`borg key export`),
- l'identifiant du dépôt (ex. `c7a620ed`).

## Dépannage

**`Error dependency ghost-mysql failed to start`** au tout premier `up` — la
première initialisation de MySQL (création des tables système) a dépassé le
budget du healthcheck, et Ghost a abandonné son `depends_on`. Les healthchecks
sont réglés large pour couvrir ce cas, mais sur un stockage très lent ça peut
encore arriver. La base initialisée persiste dans `./db` : un simple
`docker compose up -d` relance et repart de là.

**Ghost reste `unhealthy`** — `docker compose logs ghost`. Les causes
habituelles : une variable manquante dans le `.env`, ou les migrations de schéma
du premier démarrage encore en cours (elles peuvent prendre plusieurs minutes).

**Erreur de connexion à la base** — vérifier qu'aucune des variables `MYSQL_*`
n'a été modifiée depuis l'initialisation de la base.

**Traefik ne route pas** — vérifier que le réseau `frontend` existe
(`docker network ls`) et que le conteneur y est bien attaché
(`docker inspect $(docker compose ps -q ghost)`).

**Certificat non émis** — le DNS doit pointer sur le serveur *avant* le premier
démarrage, sinon le certresolver échoue et retente avec un délai.

## Ce qu'on n'a pas activé

Ghost 6 propose deux services optionnels, écartés ici pour rester simple. Ils
s'ajoutent au `docker-compose.yml` le jour où le besoin se présente (voir le
[compose officiel](https://github.com/TryGhost/ghost-docker/blob/main/compose.yml)) :

- **ActivityPub** — rend le blog suivable depuis Mastodon. Demande deux
  conteneurs supplémentaires, une seconde base MySQL, et du routage Traefik
  dédié.
- **Analytics (Tinybird)** — statistiques de trafic natives. Dépend d'un service
  tiers (compte et tokens Tinybird), potentiellement payant.

Non activés non plus : domaine d'administration séparé (`ADMIN_DOMAIN`) et
stockage des images sur S3.
