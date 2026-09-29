# Busio

App iPhone perso pour le réseau de bus **Libellus** (Castres-Mazamet) : les mêmes données que Zenbus, mieux rangées, avec ce qu'iOS sait faire de mieux (widgets, Live Activity, Siri, notifications).

- **Trajet** : l'aller le matin, le retour l'après-midi, sans rien toucher. Le bus conseillé selon ton horaire, le compte à rebours, l'heure à laquelle partir à pied (temps de marche réel calculé par Plans), le retard.
- **Carte** : tous les bus en circulation, rafraîchis toutes les 10 s, tracés des lignes, filtre par ligne.
- **Lignes** : schéma de chaque ligne avec les bus en route et le prochain passage à chaque arrêt.
- **Arrêts** : recherche, arrêts à proximité, favoris, départs groupés par ligne et direction, détail d'une course arrêt par arrêt.
- **Widgets** écran d'accueil et écran verrouillé, **Live Activity** (Dynamic Island) avec bouton d'actualisation, bouton **Centre de contrôle / bouton Action**.
- **Siri / Raccourcis** : « Prochain bus avec Busio », « Suivre mon bus avec Busio ».
- **Notifications** : « pars maintenant », retards et suppressions de ton bus.

SwiftUI iOS 26 (Liquid Glass), Swift 6, aucune dépendance serveur.

## Fiabilité des données

Busio ne doit jamais afficher un horaire faux sans le dire. Chaque horaire porte son niveau de confiance : **En direct** (bus suivi par GPS), **Estimé**, **Prévu** (grille Zenbus du jour) ou **Théorique** (horaires publiés).

| Source | Rôle |
| --- | --- |
| API Zenbus (`zenbus.net/publicapp`, protobuf) | Source principale, identique à l'app officielle : grille du jour, positions GPS, estimations, suppressions, messages trafic. |
| GTFS Libellus (data.gouv.fr, ODbL) | Secours : produit par Zenbus avec les mêmes identifiants. Un test vérifie qu'il colle à la grille réellement exploitée (100 % des courses du 28/09/2026). |
| Données embarquées | Instantané réseau + GTFS dans l'app : fonctionne dès le premier lancement, même hors ligne. |

Règles appliquées (voir `BusioKit/Sources/BusioKit/Store/TransitService.swift`) :

1. Pour chaque sens de ligne et chaque jour, **Zenbus fait foi s'il a publié la grille de ce jour**. Sinon, horaires théoriques GTFS, avec un bandeau explicite. Ce cas existe vraiment : le 29/09/2026 à 11 h, Zenbus renvoyait encore la grille de la veille.
2. Zenbus injoignable : derniers relevés du jour (sans suivi GPS), puis GTFS.
3. Un bus à quai au terminus n'est jamais considéré parti avant son heure de départ (heure serveur Zenbus).
4. Écran « Réglages › État des sources » : dernier relevé, jour publié par Zenbus, validité du GTFS, bouton pour tout retélécharger, lien vers Zenbus pour comparer.

## Installer sur ton iPhone (Apple ID gratuit)

Prérequis : un Mac avec **Xcode 26** ou plus récent, ton iPhone et un câble.

1. Clone le dépôt et ouvre le dossier :
   ```sh
   git clone https://github.com/seishiiinsan/busio.git && cd busio
   ```
2. Crée ta config de signature :
   ```sh
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```
   Dans `Config/Local.xcconfig`, mets ton **Team ID** (Xcode › Settings › Accounts › ton Apple ID : l'identifiant de la *Personal Team*) et un préfixe d'identifiant unique (ex. `fr.tonprenom`).
3. Ouvre `Busio.xcodeproj` (ou `make open` si tu as `brew install xcodegen`).
4. Branche l'iPhone, active le **Mode développeur** (Réglages › Confidentialité et sécurité), choisis l'iPhone comme destination puis **Run** (⌘R).
5. Au premier lancement : Réglages › Général › VPN et gestion de l'appareil › fais confiance à ton Apple ID.

Avec un Apple ID gratuit, l'app **expire au bout de 7 jours** : rebranche l'iPhone et relance **Run** pour la renouveler (tes réglages sont conservés).

### Live Activity automatique chaque matin

Sans compte développeur payant, pas de serveur push : iOS réveille Busio en arrière-plan quand il le juge bon. Pour un suivi garanti :

1. **Raccourcis** › Automatisation › **+** › **Heure de la journée** (ex. 8 h 30, du lundi au vendredi) › **Exécuter immédiatement**.
2. Action **Busio › Suivre mon bus**.

Le compte à rebours s'affiche sur l'écran verrouillé ; le bouton ↻ de la Live Activity le met à jour avec le temps réel. Fais la même chose vers 16 h 15 pour le retour.

## Structure

```
BusioKit/            Moteur (Swift package, testé sur Linux et macOS)
  Proto/             Sous-ensemble du protocole temps réel Zenbus
  Sources/BusioKit/  Zenbus (client + mapping), GTFS, planification, cache, trajet
  Tests/             Tests sur données réelles (Fixtures + données embarquées)
Busio/               App SwiftUI (Trajet, Carte, Lignes, Arrêts, Réglages, Accueil)
BusioWidgets/        Widgets, Live Activity, bouton de contrôle
Shared/              Code commun app + widgets (App Group, Live Activity, alertes, intents)
Config/              Réglages de signature (xcconfig)
Tools/Probe/         Sonde des API (diagnostic)
project.yml          Définition XcodeGen du projet Xcode
```

## Développement

```sh
make test      # tests du moteur (swift test)
make project   # régénère Busio.xcodeproj après modification de project.yml
make proto     # régénère le code protobuf (brew install protobuf swift-protobuf)
```

La CI (GitHub Actions, macOS) lance les tests, compile l'app et les widgets pour le simulateur à chaque push. Le workflow **Refresh seed data** met à jour les données embarquées.

### Dépannage

- *« Provisioning profile … App Groups »* : vérifie que le préfixe dans `Local.xcconfig` est unique, puis relance. L'App Group sert à partager les horaires entre l'app et les widgets.
- *Horaires « Théoriques » toute la journée* : Zenbus n'a pas publié la grille du jour ; comparer avec l'app Zenbus via Réglages › État des sources.

## Données et licence

Temps réel : Zenbus. Horaires théoriques : Communauté d'agglomération de Castres-Mazamet, GTFS Libellus sous licence ODbL (transport.data.gouv.fr). Busio n'est ni affiliée à Libellus ni à Zenbus.
