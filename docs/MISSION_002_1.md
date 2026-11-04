# Mission 002.1 — Stockage fiable et intégration

4 novembre 2026 · macOS Apple Silicon · Xcode 26.6 / Swift 6.3.3.

**Statut : Mission 002.1 validée pour le périmètre local et simulé.**
Les vérifications automatisées sont réussies et le fondateur a confirmé
les contrôles visuels assistés détaillés ci-dessous. Gmail réel reste non validé.

## Intégration

Le dossier principal `gost` a été avancé jusqu'au commit de perception
`e43a2f70c3c1d13c522e0cfc86ead3d1c2e06fe5`. Les changements locaux précédents
ont été sauvegardés puis réappliqués sans conflit. Leur copie de sécurité
reste dans le stash nommé `ghost-mission-002-1-preserve-mission-001`.

La protection de `GhostStateManager.start()` depuis PAUSED, son test et
`CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` en Release sont intégrés à la
version Perception. Les documents fondateurs ont été préservés.

## Corrections

- L'EventStore prépare les changements, écrit atomiquement puis valide son
  état en mémoire. Une écriture échouée n'empêche plus de réessayer le même événement.
- Les erreurs de lecture et de décodage sont remontées. Un fichier existant
  illisible reste intact. Un fichier absent au premier lancement reste un cas normal.
- Les suppressions modifient la mémoire après réussite sur disque. Un échec
  de suppression n'est plus ignoré par le pont vers l'interface.
- L’effacement couvre aussi les curseurs et instantanés des sources déjà révoquées, sans laisser une collecte automatique s’intercaler.
- Les erreurs au chargement apparaissent dans « Anomalies » ; les erreurs
  de suppression sont visibles dans « Confidentialité ».
- La collecte email/dossier et la validation des curseurs sont séparées.
  Le moteur sauvegarde les événements avant d'appeler `acknowledge()`.
  Un lot non sauvegardé reste en attente ; le dernier curseur durable est
  conservé. Après une panne entre sauvegarde des événements et du curseur,
  la reprise dédoublonne les événements et réessaie le curseur.
- Au redémarrage, la borne initiale des emails repose sur la date de
  l'autorisation persistée, et non sur la nouvelle date de lancement.

Le format des fichiers existants est conservé ; aucune réinitialisation ni
migration destructive n'est nécessaire.

## Tests automatisés

92 tests : 80 existants, 1 régression de Mission 001 et 11 tests de stockage/reprise.
Les nouveaux cas portent sur : écriture échouée puis réparation, JSON corrompu,
lecture réparée, suppression échouée, réessai d'un lot email, redémarrage
avant validation du curseur, échec du curseur après sauvegarde des événements,
reprise d'un dossier après panne, erreur au chargement visible dans l'interface, effacement explicite d'un curseur corrompu, et suppression des états de sources révoquées.

```sh
swift test --package-path Packages/GhostKit
xcodebuild test -project GhostShell.xcodeproj -scheme GhostShell -configuration Debug -destination 'platform=macOS' -derivedDataPath build
xcodebuild build -project GhostShell.xcodeproj -scheme GhostShell -configuration Release -destination 'platform=macOS' -derivedDataPath build
codesign --verify --strict build/Build/Products/Release/GhostShell.app
codesign -d --entitlements - build/Build/Products/Release/GhostShell.app
git diff --check
```

Les suites Swift et Xcode ont exécuté 92 tests sans échec. La compilation
Release et la signature locale ont été vérifiées. Les permissions Release
sont limitées au sandbox, au réseau sortant, au dossier sélectionné en lecture
seule et au signet de ce dossier ; aucune autorisation de débogage n'est injectée.
Les tests supplémentaires sont inclus dans le schéma Xcode.

Linux n'a pas été réexécuté pendant cette correction. Les fichiers de test
automatisé sont créés dans des répertoires temporaires isolés.

## Contrôle visuel assisté

L'outil natif contrôle Xcode, mais la lecture de GHOST expire avec
`timeoutReached`, même avec une fenêtre Perception ouverte. Les observations
visuelles ci-dessous sont donc celles du fondateur, guidé depuis le chat :

- Fenêtre Perception ouverte : confirmé par le fondateur.
- Activation de la boîte de test et événements avec badge SIMULATION : confirmé par le fondateur.
- Choix du dossier de test et collecte initiale sans erreur : confirmé par le fondateur.
- Création de `DETECTION-TEST-af0f8b.txt` détectée dans « Événements → Tous » : confirmé par le fondateur.
- État global et perception suspendus après « Mettre en pause » : confirmé par le fondateur.
- `PAUSE-TEST-d4e4f9.txt` absent en pause puis détecté après reprise : confirmé par le fondateur.
- Révocation du dossier avec conservation des événements et affichage « Aucun dossier n'est autorisé » : confirmé par le fondateur.
- `REVOCATION-TEST-dc4cda.txt` reste absent après collecte manuelle et attente : confirmé par le fondateur.
- Révocation de la simulation e-mail, suppression des événements de test puis liste vide sans erreur après redémarrage : confirmé par le fondateur.

Dossier manuel préparé : `~/Desktop/GHOST-Test-Mission-002-1`, contenant
uniquement des données fictives dédiées à ce contrôle. Aucun dossier personnel
ne doit être sélectionné pour cet essai.

## Limites

Pas de connexion Gmail réelle, pas de nouveau modèle d'IA, pas de chiffrement
applicatif ajouté. Les fichiers restent protégés par le sandbox et FileVault
si activé. Les corrections sont locales ; aucun commit ni push n'a été effectué
pour cette mission. La copie d'audit antérieure reste un instantané séparé.
