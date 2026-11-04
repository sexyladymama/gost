# GHOST — GHOST SHELL

GHOST SHELL est la première application native macOS du projet GHOST :
une application de barre de menus qui affiche et contrôle l'état de GHOST.

Cette version **ne contient aucune intelligence artificielle**, n'observe pas
l'utilisateur, ne collecte aucune donnée, n'accède ni au réseau, ni aux emails,
ni aux fichiers personnels. Elle pose uniquement les fondations (interface,
gestion d'état, point d'extension pour le futur moteur).

## Fonctionnalités

- Icône dans la barre de menus (pas d'icône dans le Dock).
- Petite fenêtre de contrôle au clic sur l'icône :
  - nom **GHOST** ;
  - statut courant : `ACTIVE`, `PAUSED` ou `STOPPED` ;
  - bouton **Mettre en pause / Reprendre** (ACTIVE ⇄ PAUSED) ;
  - bouton **Quitter GHOST** (⌘Q) qui arrête GHOST proprement (→ `STOPPED`)
    avant de fermer l'application.

## Prérequis

- macOS 14 Sonoma ou plus récent (requis par le framework `Observation`).
- Xcode 15 ou plus récent.
- Aucune dépendance externe, aucun compte développeur nécessaire
  (signature locale « Sign to Run Locally »).

## Lancer l'application

### Avec Xcode

1. Ouvrir `GhostShell.xcodeproj`.
2. Sélectionner le schéma **GhostShell** et la destination **My Mac**.
3. `Product ▸ Run` (⌘R).
4. L'icône GHOST apparaît dans la barre de menus, en haut à droite de l'écran.
   Cliquer dessus pour ouvrir la fenêtre de contrôle.

### En ligne de commande

```bash
xcodebuild build -project GhostShell.xcodeproj -scheme GhostShell -configuration Debug -destination 'platform=macOS' -derivedDataPath build
```

```bash
open build/Build/Products/Debug/GhostShell.app
```

## Tests

Les tests couvrent la logique de changement d'état (`GhostStateMachine`,
`GhostStateManager`) et la communication avec le moteur.

- Dans Xcode : `Product ▸ Test` (⌘U) avec le schéma **GhostShell**.
- En ligne de commande (macOS ou Linux, sans Xcode) :

```bash
swift test --package-path Packages/GhostKit
```

## Architecture

```
gost/
├── GhostShell.xcodeproj         Projet Xcode (cible app + schéma partagé)
├── GhostShell/                  Couche interface (SwiftUI / AppKit)
│   ├── GhostApp.swift           Point d'entrée (@main)
│   ├── GhostAppDelegate.swift   Cycle de vie : démarrage, arrêt propre
│   ├── GhostShell.entitlements  Bac à sable, aucune autorisation
│   └── UI/
│       ├── GhostMenuBar.swift           Icône + MenuBarExtra
│       ├── GhostDashboard.swift         Fenêtre de contrôle
│       └── GhostState+Appearance.swift  Icônes et couleurs des états
└── Packages/GhostKit/           Logique, sans aucune dépendance à l'UI
    ├── Sources/GhostKit/
    │   ├── GhostState.swift          ACTIVE / PAUSED / STOPPED
    │   ├── GhostStateMachine.swift   Règles de transition (fonctions pures)
    │   ├── GhostStateManager.swift   Source de vérité observable
    │   └── GhostCoreInterface.swift  Protocole du futur moteur + IdleGhostCore
    └── Tests/GhostKitTests/          Tests XCTest
```

Flux : `GhostDashboard` → `GhostStateManager` (valide la transition via
`GhostStateMachine`) → `GhostCoreInterface` (notifié de la transition).

### Transitions autorisées

| Depuis    | Vers      | Méthode         |
|-----------|-----------|-----------------|
| `STOPPED` | `ACTIVE`  | `start()`       |
| `ACTIVE`  | `PAUSED`  | `pause()`       |
| `PAUSED`  | `ACTIVE`  | `resume()`      |
| `ACTIVE`  | `STOPPED` | `stop()`        |
| `PAUSED`  | `STOPPED` | `stop()`        |

`togglePause()` bascule ACTIVE ⇄ PAUSED et lève une erreur si GHOST est arrêté.
`stop()` est idempotent. Toute autre transition lève `GhostTransitionError`.

### Brancher un futur moteur

Le moteur central devra se conformer à `GhostCoreInterface`, puis être injecté :

```swift
let stateManager = GhostStateManager(core: MonMoteur())
```

L'interface n'a pas à être modifiée. Par défaut, `IdleGhostCore` est utilisé :
il ne fait strictement rien.
