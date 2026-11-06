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

## Références du projet

- [Dossier fondateur GHOST](docs/GHOST_FOUNDATION.md) : vision et décisions transmises par le fondateur.
- [Audit Mission 001 du 4 novembre 2026](docs/MISSION_001_AUDIT.md) : résultats techniques et vérifications restantes.
- [Mission 002.1](docs/MISSION_002_1.md) : corrections de stockage, reprise après panne et validation.
- [GHOST CONTEXT (Mission 003)](docs/CONTEXT.md) : mémoire et compréhension contextuelle, cloisonnement, preuves, corrections.
- [GHOST BRAIN (Mission 004)](docs/BRAIN.md) : décisions, missions, priorités, plans ; [évaluation chiffrée](docs/BRAIN_EVALUATION.md).
- [GHOST CORE (Mission 008)](docs/CORE.md) : un objectif en langage naturel, une boucle d'agent bornée, des outils réels, un accord lié à l'action exacte.
- [GHOST MIND (Mission 007)](docs/MIND.md) : GHOST comprend la demande et fait le travail : mails, recherche de lieux, logos et documents.
- [GHOST VISION (Mission 006)](docs/VISION.md) : lecture de l'écran en local, vie privée, rendez-vous ajoutés à l'agenda.
- [GHOST AUTONOMY (Mission 005)](docs/AUTONOMY.md) : exécution locale d'un scénario Excel de bout en bout, Trust, vérification, reprise.
- [Audit des Missions 003/004](docs/AUDIT_MISSIONS_003_004.md) : corrections, tests supplémentaires et limites vérifiées.

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
- *Missions* : ce que GHOST a décidé de suivre, pourquoi, avec priorité, plan, manques, autorisations, preuves et historique ; il **propose, vous décidez** (rien n'est exécuté) ;
- *Brouillons / Recherches / Créations* : GHOST rédige un mail (Envoyer / Refaire / Annuler, jamais d'envoi sans votre clic), cherche des lieux, crée logos et documents dans le dossier que vous choisissez ;
- *Agenda* : rendez-vous vus à l'écran, ajoutés directement (vérifiés, sans doublon, annulables en un clic) ou proposés ; GHOST regarde l'écran **après consentement** (écran de bienvenue), ignore mots de passe, banque et navigation privée, ne garde aucune image, pause immédiate avec ⌃⌥⌘G ;
- *Activité* : exécution locale d'une mission Excel confirmée (autorisation séparée des dossiers, progression, pause, annulation, vérification) ;
- *Mémoire* : ce que GHOST comprend (projets, personnes, documents, demandes, échéances), statut confirmé / hypothèse / inconnu, preuves, corrections ;
- *Confidentialité* : garanties, arrêt complet, **suppression des données collectées et de la mémoire**.

**Sources**
- *E-mail* : boîte de test **simulée** (par défaut, aucun réseau) ou compte
  **Gmail réel** via OAuth, en lecture seule (voir [docs/GMAIL_SETUP.md](docs/GMAIL_SETUP.md)) ;
- *Dossier local* : un dossier choisi dans le sélecteur macOS ; seules les
  métadonnées des fichiers sont observées.

## Prérequis

- macOS 14 Sonoma ou plus récent ;
- Xcode 15 ou plus récent (CI : Xcode 16.4 sur macOS 15) ;
- une seule dépendance externe, [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) 0.9.20 (MIT, version épinglée, module GhostAutonomy) : le premier `swift build`/Xcode a besoin d'un accès réseau pour la récupérer ; aucun compte développeur (signature locale) ;
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

Les tests couvrent la logique d'état de la Mission 001 et les exigences
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

Les tests de `ReviewRegressionTests` vérifient aussi les échecs d'écriture,
la préservation d'un stockage illisible et la reprise des sources après panne.
Les erreurs de stockage apparaissent dans « Anomalies » ; les erreurs de
suppression sont également affichées dans « Confidentialité ».

## Architecture

```
gost/
├── GhostShell.xcodeproj              Projet Xcode (GhostShell + GhostShellTests)
├── GhostShell/                       Couche interface (SwiftUI / AppKit)
│   ├── GhostApp.swift                Point d'entrée (@main)
│   ├── GhostAppDelegate.swift        Cycle de vie : démarrage, restauration des sources, arrêt
│   ├── GhostShell.entitlements       Bac à sable : réseau, dossiers choisis, agenda, automatisation Mail
│   ├── Perception/
│   │   ├── PerceptionController.swift   Actions utilisateur sur les sources
│   │   ├── GmailAuthorizer.swift        Fenêtre d'authentification Google
│   │   └── SecurityScopedFolder.swift   Signets de dossiers (sources en lecture seule, sorties en écriture)
│   └── UI/                           Barre de menus, tableau de bord, fenêtre Perception
├── Packages/GhostKit/                Logique, sans aucune dépendance à l'UI
│   ├── Sources/GhostKit/             États de GHOST, GhostCoreInterface (Mission 001)
│   ├── Sources/GhostPerception/      Moteur de perception (Mission 002)
│   ├── Sources/GhostContext/         Mémoire contextuelle, SQLite local (Mission 003)
│   ├── Sources/GhostBrain/           Cerveau décisionnel : objectifs, décisions, missions, plans (Mission 004)
│   ├── Sources/GhostAutonomy/        Exécution locale vérifiée (Mission 005)
│   ├── Sources/GhostVision/          Lecture de l'écran (OCR local), rendez-vous, agenda (Mission 006)
│   ├── Sources/GhostMind/            Comprendre la demande et faire : mails, lieux, logos, documents (Mission 007)
│   └── Tests/                        Tests XCTest
└── docs/
    ├── PERCEPTION.md                 Documentation technique du moteur
    ├── CONTEXT.md                    Mémoire et compréhension contextuelle
    ├── BRAIN.md                      Cerveau décisionnel et missions
    ├── AUTONOMY.md                   Moteur d'exécution local
    ├── VISION.md                     Lecture de l'écran et agenda
    ├── MIND.md                       Comprendre et faire : mails, lieux, créations
    ├── BRAIN_EVALUATION.md           Évaluation chiffrée (générée par les tests)
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

- Gmail et les métadonnées du dossier surveillé sont lus après autorisation ; le contenu CSV/TSV et le dossier de sortie d'une exécution Excel nécessitent des autorisations séparées.
- La lecture de l'écran exige votre consentement et l'autorisation macOS. L'OCR reste local ; les images sont abandonnées, les extraits utiles sont conservés. Le filtre exclut les fenêtres sensibles connues ; il ne garantit pas de reconnaître tout contenu privé.
- Le modèle Apple reste sur le Mac. Le modèle externe (Anthropic), Apple Plans et DuckDuckGo exigent leurs autorisations respectives. Les noms connus et les adresses e-mail sont masqués avant l'envoi au modèle externe ; cela ne constitue pas une anonymisation complète du texte.
- Un mail ne part que sur le clic **Envoyer**. L'ajout automatique de rendez-vous dépend du consentement agenda. Un envoi ou un ajout déjà engagé peut finir après la demande de pause.
- Les créations utilisent le dossier choisi, sans écrasement ; les dossiers échangés et les liens à leur place sont refusés. Les jetons restent dans le Trousseau ; la mémoire locale n'a pas de chiffrement applicatif supplémentaire.
- Supprimer les données de GHOST efface ses registres et sa mémoire. Les fichiers produits et les rendez-vous déjà ajoutés restent dans vos applications ; les autorisations peuvent être révoquées dans Sources.

L'[audit du 6 novembre 2026](docs/AUDIT_2026_11_06.md) détaille les corrections et les vérifications réellement effectuées.
