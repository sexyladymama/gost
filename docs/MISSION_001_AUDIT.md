# Mission 001 — Audit GHOST SHELL

4 novembre 2026 · macOS Apple Silicon · Xcode 26.6 · Swift 6.3.3

## Conclusion

Le code est disponible localement dans le dépôt `gost`, lié à
`https://github.com/sexyladymama/gost.git`. L'accès distant n'a pas été testé.
La compilation et les tests sont validés. La validation complète de Mission 001
reste conditionnée au contrôle de l'interface en fonctionnement.

Audit réalisé à partir du commit `95c9e0b083dbf589bc02b86e988be263759b991a`,
avec les corrections locales décrites ci-dessous.

## Périmètre vérifié

- Application SwiftUI native avec `MenuBarExtra`, panneau de contrôle et `LSUIElement` activé.
- Trois états : `ACTIVE`, `PAUSED`, `STOPPED` ; commandes pause, reprise et fermeture.
- Logique isolée dans le package `GhostKit`, avec injection d'un `GhostCoreInterface`.
- Moteur par défaut `IdleGhostCore` sans traitement ni connexion.
- Aucun code de capture d'écran, d'accès aux emails, de collecte ou d'appel réseau dans les sources inspectées.
- Entitlements source limités au bac à sable macOS ; signature locale, sans certificat de distribution.

`STOPPED` est l'état initial et l'état de fermeture : aucun bouton d'arrêt
maintenant le panneau ouvert n'est prévu dans cette version.
Les notifications et l'intelligence centrale restent à développer.

## Corrections

1. `start()` acceptait un gestionnaire en pause, car la transition `PAUSED → ACTIVE`
   est valide pour `resume()`. Cela déclenchait à tort `core.start()`.
   Le démarrage exige maintenant `STOPPED`. Un test de régression démontre
   l'échec avant correction puis vérifie le refus sans modifier l'état ni
   redémarrer le moteur, suivi d'une reprise normale.
2. La signature locale Release héritait d'une autorisation de débogage
   (`get-task-allow`). L'injection des entitlements de développement est désactivée
   pour cette configuration. Debug conserve sa configuration de test Xcode.

## Vérifications automatisées

```sh
swift test --package-path Packages/GhostKit
xcodebuild test -project GhostShell.xcodeproj -scheme GhostShell -configuration Debug -destination 'platform=macOS' -derivedDataPath build
xcodebuild build -project GhostShell.xcodeproj -scheme GhostShell -configuration Release -destination 'platform=macOS' -derivedDataPath build
codesign --verify --strict build/Build/Products/Release/GhostShell.app
codesign -d --entitlements - build/Build/Products/Release/GhostShell.app
git diff --check
```

Les deux suites exécutent les mêmes **19 tests**, sans échec. La compilation
Release réussit. La signature locale est vérifiée ; le binaire Release
ne doit contenir que `com.apple.security.app-sandbox = true`.
Ces tests couvrent le gestionnaire d'état et ses appels au moteur, pas les clics
dans l'interface ni le cycle de fermeture réel de l'application.

Les résultats Xcode sont conservés dans `build/Logs/Test/` (dossier non versionné).
Xcode émet un avertissement d'extraction App Intents sans dépendance AppIntents ;
aucune intégration App Intents n'est prévue dans ce shell.

## Vérification visuelle restante

L'application Debug a été lancée et son processus a été observé. Deux tentatives
de lecture de l'interface par l'outil de contrôle natif ont expiré
(`timeoutReached`). Le rendu et les interactions ne sont donc pas attestés.

Dans Xcode, ouvrir le projet, sélectionner `GhostShell` / `My Mac` puis lancer :

- [ ] Vérifier la présence d'une seule icône dans la barre de menus et l'absence d'icône dans le Dock.
- [ ] Ouvrir le panneau et vérifier `ACTIVE`.
- [ ] Cliquer sur « Mettre en pause » : vérifier `PAUSED`, l'icône et le bouton « Reprendre ».
- [ ] Cliquer sur « Reprendre » : vérifier le retour à `ACTIVE`.
- [ ] Quitter avec le bouton, relancer, puis quitter avec ⌘Q depuis le panneau.
- [ ] Vérifier l'absence de demande de permission sensible.

## Suite du projet

Une fois ces contrôles effectués, valider Mission 001 avant de commencer
GHOST CORE. Le cerveau adaptatif, la mémoire, les emails, le cloud et
la réalisation de missions restent des objectifs du dossier fondateur ;
ils ne sont pas implémentés dans ce shell.
