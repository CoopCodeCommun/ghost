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

## Sauvegarde et mise à jour

Voir [`scripts/README.md`](./scripts/README.md).

En résumé : `scripts/backup_ghost.sh` pousse un dump MySQL et le dossier
`content/` dans une archive borg unique, quotidiennement par cron.
`scripts/update_ghost.sh` rejoue cette sauvegarde avant chaque `docker compose
pull`, puis attend que Ghost repasse au vert.

Les données vivent dans deux dossiers du dépôt, créés par Docker au premier
démarrage :

| Dossier | Contenu |
|---|---|
| `./ghost/` | Images, thèmes, paramètres (`content/` de Ghost) |
| `./db/` | Fichiers de la base MySQL |

## Restauration

Depuis une archive borg (à faire depuis le dossier de la stack) :

```bash
cd /opt/ghost

# Charger les identifiants du dépôt (les mêmes que dans backup_ghost.sh)
export BORG_REPO='ssh://borgwarehouse@…/./xxxxxxxx'
export BORG_PASSPHRASE='…'
export BORG_RSH="ssh -i /opt/ghost/scripts/.ssh/ghost_rtlx_ed25519 -oIdentitiesOnly=yes"

borg list                                    # choisir l'archive
borg extract --list "$BORG_REPO::<archive>"  # extrait dans le dossier courant

# L'extraction recrée l'arborescence absolue d'origine, sans le / initial :
#   opt/ghost/scripts/mysql-dump-<prefix>/ghost.sql   <- le dump
#   opt/ghost/ghost/                                  <- le contenu

# 1. Restaurer les fichiers
docker compose stop ghost
rsync -a --delete opt/ghost/ghost/ ./ghost/

# 2. Restaurer la base
docker compose up -d ghost-mysql
docker compose exec -T ghost-mysql \
  sh -c 'exec mysql -u root -p"$MYSQL_ROOT_PASSWORD" ghost' \
  < opt/ghost/scripts/mysql-dump-<prefix>/ghost.sql

# 3. Redémarrer
docker compose up -d
docker compose logs -f ghost
```

Si la restauration fait suite à une mise à jour ratée, remettre aussi le
`docker-compose.yml` sur la version d'image précédente **avant** de redémarrer :
une base restaurée depuis une version antérieure ne sera pas lue par un Ghost
plus récent tant qu'il n'a pas rejoué ses migrations, et un Ghost plus ancien
refuse de démarrer sur un schéma trop récent.

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
