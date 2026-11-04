# GHOST — GHOST SHELL & GHOST PERCEPTION

GHOST SHELL est l'application native macOS de GHOST : elle vit dans la barre
de menus et affiche et contrôle l'état de GHOST (ACTIVE / PAUSED / STOPPED).

GHOST PERCEPTION (Mission 002) est son premier moteur de perception : à partir
de sources que **vous autorisez explicitement** (une boîte e-mail et un
dossier local), il détecte les nouveaux éléments, les comprend (demande,
tâche, échéance, relance, information…), explique pourquoi, et les enregistre
comme événements structurés pour les futurs moteurs de GHOST.

GHOST PERCEPTION **perçoit et comprend, mais n'agit pas** : il n'envoie aucun
e-mail, ne modifie ni ne supprime aucun fichier et n'exécute aucune tâche.

## Fonctionnalités

**Barre de menus et fenêtre de contrôle**
- icône dont l'aspect reflète l'état, avec le nombre d'événements importants non consultés ;
- statut GHOST et état de la perception, sources actives, anomalies, derniers événements importants ;
- **Mettre en pause / Reprendre** (la collecte est réellement suspendue en pause) ;
- **Arrêter / Démarrer la perception** ;
- **Quitter GHOST** (⌘Q) avec arrêt propre.

**Fenêtre « GHOST — Perception »** (lien « Voir ce que GHOST a détecté… »)
- *Événements* : liste et détail, avec type, personnes, action attendue,
  résultat attendu, informations nécessaires, échéance, confiance, et
  **« Pourquoi GHOST l'a détecté »** (règles déclenchées et extraits) ;
- *Anomalies* : erreurs de connexion, d'autorisation ou d'accès ;
- *Sources* : activer/désactiver, connecter, **révoquer** chaque source ;
- *Journal d'accès* : chaque accès à une source (autorisé, refusé, échec) ;
- *Confidentialité* : garanties, arrêt complet, **suppression des données collectées**.

**Sources**
- *E-mail* : boîte de test **simulée** (par défaut, aucun réseau) ou compte
  **Gmail réel** via OAuth, en lecture seule (voir [docs/GMAIL_SETUP.md](docs/GMAIL_SETUP.md)) ;
- *Dossier local* : un dossier choisi dans le sélecteur macOS ; seules les
  métadonnées des fichiers sont observées.

## Prérequis

- macOS 14 Sonoma ou plus récent ;
- Xcode 15 ou plus récent (CI : Xcode 16.4 sur macOS 15) ;
- aucune dépendance externe, aucun compte développeur (signature locale) ;
- pour Gmail réel uniquement : un projet Google Cloud et un ID client OAuth
  ([procédure](docs/GMAIL_SETUP.md)).

## Installation et lancement

### Avec Xcode

1. Cloner le dépôt et ouvrir `GhostShell.xcodeproj`.
2. Schéma **GhostShell**, destination **My Mac**, puis `Product ▸ Run` (⌘R).
3. L'icône GHOST apparaît dans la barre de menus. Cliquer dessus, puis
   **Voir ce que GHOST a détecté… ▸ Sources** :
   - **Utiliser la boîte de test (simulation)** : un e-mail fictif arrive toutes
     les 20 s environ (7 au total) ;
   - **Choisir un dossier…** : sélectionner un dossier de test, puis y déposer ou
     modifier des fichiers (détection en ~5 s).

### En ligne de commande

```bash
xcodebuild build -project GhostShell.xcodeproj -scheme GhostShell -configuration Debug -destination 'platform=macOS' -derivedDataPath build
```

```bash
open build/Build/Products/Debug/GhostShell.app
```

## Tests

```bash
swift test --package-path Packages/GhostKit
```

ou, dans Xcode, `Product ▸ Test` (⌘U) avec le schéma **GhostShell**.

Les tests (80) couvrent la logique d'état de la Mission 001 et les exigences
de la Mission 002 (préfixes `testR01_` à `testR10_`) :

| # | Exigence | Tests |
|---|----------|-------|
| 1 | Un nouvel e-mail est détecté | `EmailPerceptionTests.testR01_*` |
| 2 | Une demande est identifiée | `EmailPerceptionTests.testR02_*` |
| 3 | Une échéance est extraite | `EmailPerceptionTests.testR03_*`, `DeadlineExtractorTests` |
| 4 | Un e-mail informatif n'est pas une mission | `EmailPerceptionTests.testR04_*` |
| 5 | Un nouveau fichier est détecté | `FolderPerceptionTests.testR05_*` |
| 6 | Un dossier non autorisé n'est jamais inspecté | `FolderPerceptionTests.testR06_*` |
| 7 | La pause arrête réellement la perception | `EngineTests.testR07_*` |
| 8 | Une erreur de connexion est gérée | `EngineTests.testR08_*` |
| 9 | Pas de doublons | `StoreAndPrivacyTests.testR09_*` |
| 10 | Aucune transmission non autorisée | `StoreAndPrivacyTests.testR10_*` |

Les services externes sont simulés dans les tests (réponses HTTP Gmail
enregistrées, aucune connexion réelle).

## Architecture

```
gost/
├── GhostShell.xcodeproj              Projet Xcode (GhostShell + GhostShellTests)
├── GhostShell/                       Couche interface (SwiftUI / AppKit)
│   ├── GhostApp.swift                Point d'entrée (@main)
│   ├── GhostAppDelegate.swift        Cycle de vie : démarrage, restauration des sources, arrêt
│   ├── GhostShell.entitlements       Bac à sable : réseau sortant, dossier choisi en lecture seule
│   ├── Perception/
│   │   ├── PerceptionController.swift   Actions utilisateur sur les sources
│   │   ├── GmailAuthorizer.swift        Fenêtre d'authentification Google
│   │   └── SecurityScopedFolder.swift   Signet de dossier en lecture seule
│   └── UI/                           Barre de menus, tableau de bord, fenêtre Perception
├── Packages/GhostKit/                Logique, sans aucune dépendance à l'UI
│   ├── Sources/GhostKit/             États de GHOST, GhostCoreInterface (Mission 001)
│   ├── Sources/GhostPerception/      Moteur de perception (Mission 002)
│   └── Tests/                        Tests XCTest
└── docs/
    ├── PERCEPTION.md                 Documentation technique du moteur
    └── GMAIL_SETUP.md                Connexion d'une boîte Gmail de test
```

Flux : sources autorisées → `PerceptionEngine` → `EventNormalizer` →
`UnderstandingEngine` → `EventStore` → `PerceptionCenter` (implémente
`GhostCoreInterface`) → interface. Détails : [docs/PERCEPTION.md](docs/PERCEPTION.md).

### États de GHOST (Mission 001)

| Depuis    | Vers      | Méthode   | Effet sur la perception |
|-----------|-----------|-----------|--------------------------|
| `STOPPED` | `ACTIVE`  | `start()` | collecte démarrée |
| `ACTIVE`  | `PAUSED`  | `pause()` | collecte suspendue |
| `PAUSED`  | `ACTIVE`  | `resume()`| collecte reprise |
| `ACTIVE`/`PAUSED` | `STOPPED` | `stop()` | collecte arrêtée |

## Confidentialité

- Aucune source n'est lue sans action explicite de votre part ; chaque accès est journalisé.
- Aucune capture d'écran, aucune frappe clavier, aucune observation d'applications.
- E-mail en lecture seule (`gmail.readonly`) ; dossier : métadonnées uniquement.
- Seuls `gmail.googleapis.com` et `oauth2.googleapis.com` sont joignables, et
  seulement pour la source Gmail ; toute autre destination est bloquée.
- Jetons dans le Trousseau macOS ; données dans le conteneur de l'application,
  séparées par utilisateur ; suppression en un clic.
