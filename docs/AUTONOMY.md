# GHOST AUTONOMY — Mission 005

Premier moteur d'**exécution** de GHOST : à partir d'une mission planifiée par GHOST BRAIN, il transforme la
mission en opérations, les exécute avec un catalogue fermé d'outils, vérifie lui-même le résultat, journalise tout
et rend compte au Brain. Cette version réalise **un seul scénario, de bout en bout et entièrement local** :
des CSV/TSV commerciaux autorisés deviennent un classeur Excel vérifié dans un dossier de sortie autorisé.

> **Périmètre honnête.** GHOST sait maintenant *faire* ce scénario. Il ne sait pas encore modifier, déplacer ou
> supprimer un fichier, ni envoyer quoi que ce soit : aucun outil à conséquence externe n'existe, et le Trust Engine
> refuse par construction tout outil de niveau 3. Le « cloud » est une interface préparée, volontairement indisponible.

## Flux

```
Brain : mission Excel CONFIRMÉE et READY ─► ExecutionEngine.prepare ─► plan local à 6 opérations
        ─► autorisation SÉPARÉE des deux dossiers (sélecteur macOS) ─► start
        ListAuthorizedFiles → ReadAuthorizedFile → CreateSpreadsheet → SaveArtifact → VerifyArtifact → NotifyUser
        ─► Brain : trace « livrable local créé et vérifié » (la mission n'est PAS marquée terminée : la remise reste à faire)
```

## Modules (`Packages/GhostKit/Sources/GhostAutonomy/`)

| Fichier | Rôle |
|---|---|
| `ExecutionEngine.swift` | Ordonnanceur : états, dépendances, reprise, pause/annulation, tentatives bornées, retour au Brain |
| `ExecutionModel.swift` | États et transitions, `ExecutionContext`, catalogue d'outils, backends local/cloud, rapports |
| `ToolEngine.swift` | Exécute un outil du catalogue ; schémas stricts, aucun argument superflu, aucune commande |
| `ExecutionTrust.swift` | Trust d'exécution (indépendant de Perception et des modèles) et `SecureFiles` (accès fichiers bornés) |
| `SpreadsheetEngine.swift` | Lecture CSV/TSV, création XLSX natif, **vérification indépendante** du classeur |
| `ExecutionStore.swift` | Checkpoints atomiques `executions.json`, fichier illisible ou d'une autre version jamais écrasé |
| `ExecutionCenter.swift` | Pont observable pour SwiftUI ; vue **Activité** dans `GhostShell/UI/AutonomyView.swift` |

### Execution Engine

États : `pending`, `authorized`, `running`, `waiting_for_approval`, `paused`, `verifying`, `completed`, `failed`, `cancelled`
(`ExecutionState.canMove` valide chaque transition ; `completed` et `cancelled` sont terminaux). Une exécution n'est créée que
pour une mission **confirmée par l'utilisateur, `READY`, sans ambiguïté ni information manquante** ; elle est liée à la mission par
une empreinte (`binding`) : si l'objectif change ou si la mission est annulée, l'exécution s'arrête pour révision humaine. L'identifiant
d'exécution et ceux des opérations sont stables ; chaque opération est checkpointée avant et après. Trois tentatives au plus par
opération pour les erreurs *temporaires* ; une erreur de validation ne se rejoue jamais.

### Tool Engine — catalogue fermé

| Outil | Rôle | Permission | Risque |
|---|---|---|---|
| `ListAuthorizedFiles` | Liste les CSV/TSV (≤ 100) du dossier source | `read_content` | niveau 1 |
| `ReadAuthorizedFile` | Lit les fichiers listés (≤ 20 Mo, UTF-8) + SHA-256 | `read_content` | niveau 1 |
| `CreateDocument` | Prépare un texte UTF-8 en mémoire | — | niveau 1 |
| `CreateSpreadsheet` | Construit le XLSX en mémoire (formules `SUM`, quantité × prix) | — | niveau 1 |
| `SaveArtifact` | Crée un **nouveau** fichier dans le dossier de sortie ; n'écrase jamais | `create_output` | niveau 1 |
| `VerifyArtifact` | Relit le fichier enregistré et le contrôle | `read_output` | niveau 1 |
| `NotifyUser` | Message de fin, seulement après vérification réussie ; aucun envoi | — | niveau 1 |

Un nom d'outil inconnu (`RunShell`, `SendEmail`, `DeleteFile`…) n'existe pas dans `ToolID` : il est refusé avant toute évaluation.
Aucun code, script ni commande n'est exécuté ; un modèle ne peut proposer que des opérations du catalogue.

### Trust Engine d'exécution

Indépendant des modèles et des permissions de Perception : lire le contenu d'un fichier et écrire dans un dossier sont des
autorisations **distinctes**, accordées *par exécution* et *par espace de noms* (personnel / professionnel / simulé).

| Niveau | Contenu | Comportement implémenté |
|---|---|---|
| 1 — local, faible risque | lecture autorisée, création d'un nouveau fichier, vérification | automatique **si** les deux dossiers sont autorisés |
| 2 — sensible | données déclarées sensibles ; fichier de sortie déjà existant | **validation explicite** (`waiting_for_approval`) ; un fichier existant n'est jamais remplacé : approbation d'une *nouvelle version* `-v2` |
| 3 — externe | envoi, achat, partage, publication, suppression définitive | **toujours refusé** : aucun outil de ce niveau n'est enregistré |

Les modifications, remplacements et déplacements de fichiers existants ne sont **pas implémentés** (aucun outil), ils ne sont donc pas
« à valider » : ils sont impossibles.

### Verification Engine

`SpreadsheetEngine.verify` relit le fichier **enregistré** (pas l'artefact en mémoire) et contrôle : paquet ZIP et CRC, six composants
XML bien formés sans DOCTYPE/entité/macro/lien externe, nombre et unicité des cellules, chaque produit, quantité, prix et provenance,
formules `=B*C` et `SUM`, totaux **recalculés indépendamment en centimes entiers**, et l'empreinte égale à celle sauvegardée. Statuts :
`passed`, `failed`, `warning`, `needs_review`. Une exécution ne passe `completed` qu'avec `passed` ; un échec la met en `failed` sans
jamais notifier un succès.

### Recovery Engine

- Checkpoints persistants (`executions.json`, écriture atomique) après chaque opération ; `recover()` au lancement place toute exécution
  interrompue en `paused` et exige une **nouvelle autorisation des dossiers** (aucun accès n'est conservé d'un lancement à l'autre).
- Avant reprise, les sources sont relues et comparées à leur empreinte : si l'une a changé, la reprise est refusée (pas de données périmées).
- Idempotence : le nom de sortie est imposé (`GHOST-<id>-v<n>.xlsx`) ; si le fichier existe **et est identique** (même SHA-256), il est
  « récupéré » sans réécriture ; s'il diffère ou est partiel, une approbation de nouvelle version est demandée.
- Création en `O_CREAT|O_EXCL|O_NOFOLLOW`, `fsync` du fichier et du dossier.

### Séparation des contextes

Chaque exécution a son `ExecutionContext` (mission, plan, permissions, entrées lues, résultats, erreurs, historique, dates) et son
autorisation propre, liée à l'espace de noms de la mission : une autorisation d'un contexte professionnel ne sert pas à un autre.

### Local / cloud

`ExecutionCapability` distingue `local` et `cloud`. `LocalExecutionBackend` prend en charge les 7 outils ; `CloudExecutionBackend` est
une **interface préparée mais indisponible** (aucun serveur n'existe) : `prepare(…, capability: .cloud)` est refusé avec un message explicite
et ne crée aucune exécution. Un serveur ne peut pas contrôler une application du Mac, surtout éteint : seules des opérations sans dépendance
à l'environnement local pourraient un jour passer par un backend cloud.

### Retour vers GHOST BRAIN

- Succès : `recordVerifiedLocalArtifact` (nom, empreinte, contrôles) ; les étapes de collecte/construction/contrôle du plan du Brain sont
  marquées terminées et la validation devient `READY`. **La mission n'est pas `COMPLETED`** : la validation du destinataire et la remise externe
  n'ont pas eu lieu.
- Pause, annulation, approbation requise, refus de permission, échec : `recordExecutionEvent` ajoute une trace (actions déjà effectuées,
  étapes restantes). Cette trace **n'altère ni l'état ni le plan** : seul le Brain décide de l'état d'une mission.

### Interface (GHOST ▸ Activité)

Missions éligibles, progression, opérations et tentatives, étape en cours, erreurs, demande d'approbation (données sensibles, nouvelle
version), vérification détaillée, historique, « Afficher dans Finder ». Contrôles : **Pause**, **Reprendre** (réautorise les dossiers),
**Annuler**, **Révoquer les dossiers** (arrêt immédiat), **Refuser**. La pause/l'arrêt de GHOST suspend aussi les exécutions.

## Décisions d'architecture importantes

### 1. Accès aux dossiers dans le bac à sable macOS (problème trouvé et corrigé)

Le bac à sable n'autorise que le dossier choisi dans le sélecteur et son contenu, **pas ses dossiers parents**. La première version
ouvrait le dossier en parcourant chaque composant depuis `/` (anti-lien symbolique) et canonicalisait avec `realpath`. Reproduit avec
`scripts/verify-sandbox-folder-access.sh` : sous un profil qui interdit les parents, le parcours depuis `/` échoue (même avec `O_EVTONLY`),
`realpath` est refusé, alors que l'ouverture directe et `fcntl(F_GETPATH)` fonctionnent. Correctif : ouverture **directe** du dossier autorisé
(`O_NOFOLLOW`), chemin canonique calculé par `F_GETPATH` sur le descripteur, et trois contrôles à chaque accès — dernier composant non suivi
s'il est un lien, chemin réel du descripteur identique au chemin autorisé (un parent remplacé par un lien est détecté), identité
(périphérique, inode) identique (un dossier échangé est détecté). Ces cas sont couverts par des tests. **Limite :** validé par émulation
`sandbox-exec`, pas dans l'application réellement lancée avec le sélecteur (voir « Vérifications manuelles restantes »).

### 2. Droit d'écriture sur le dossier choisi

`com.apple.security.files.user-selected.read-only` devient `read-write` : indispensable pour créer le livrable dans le dossier de sortie.
Conséquence : l'application *peut* techniquement écrire dans tout dossier que l'utilisateur sélectionne (y compris le dossier surveillé par
Perception, dont le signet reste en lecture seule). La limitation à « création de nouveaux fichiers dans le dossier de sortie d'une exécution
autorisée » est assurée par le code (`ExecutionTrust`, `SecureFiles.save`, `O_EXCL`), pas par le système. Le dossier de sortie doit être
distinct de la source (refusé sinon).

### 3. Dépendance externe : ZIPFoundation 0.9.20 (MIT, version épinglée)

Un `.xlsx` est un paquet ZIP ; la vérification exige de le relire (CRC, contenu). Écrire soi-même un lecteur ZIP sûr (zip bombs,
chemins relatifs, entrées dupliquées) est plus risqué qu'une bibliothèque éprouvée. Aucune macro, aucun réseau à l'exécution ; la résolution du
paquet nécessite un accès réseau à la première compilation (GitHub) et en CI. Les autres modules n'ont toujours aucune dépendance externe.

### 4. Plan d'exécution dérivé du Brain, pas copié

Le moteur dérive son propre plan local à 6 opérations à partir d'une mission Excel confirmée plutôt que d'exécuter les étapes du plan du Brain
une à une (celles-ci contiennent des étapes de validation et de remise externe qui ne relèvent pas de cette version). Le lien est maintenu par
l'empreinte de la mission et le retour d'état ci-dessus.

## Tests

`swift test --package-path Packages/GhostKit --filter GhostAutonomyTests` :

| Exigence | Test |
|---|---|
| A, B, F, N, O — mission reçue, outils dans l'ordre, fichier présent sur le disque, résultat transmis au Brain, scénario Excel complet | `testA_B_F_N_O_realSpreadsheetWorkflowAndBrainReport` |
| C, E, M — action interdite bloquée, outil externe impossible, permission révoquée | `testC_E_M_permissionsAndExternalActionsAreDenied` |
| D — donnée sensible : approbation requise | `testD_sensitiveDataRequiresExplicitApproval` |
| G, H — classeur/source invalide détecté, une erreur ne fait jamais passer `completed` | `testG_H_invalidSpreadsheetAndInvalidSourcesNeverComplete` |
| I, J, P — reprise après redémarrage, pas de réécriture, persistance | `testI_J_P_recoveryAfterSaveDoesNotRewriteArtifact` |
| K, L — pause puis reprise, annulation | `testK_pauseThenResume`, `testL_cancelStopsFollowingOperations` |
| Collision (jamais d'écrasement) | `testCollisionRequiresNewVersionApprovalWithoutOverwrite` |
| Liens, `..`, dossier échangé | `testSymlinksTraversalAndDirectorySwapAreBlocked` |
| Révocation d'une source | `testSourceRevocationPurgesExecutionAndPreventsResume` |
| Machine à états, outils inconnus, arguments stricts | `testStateMachineAndUnknownTools`, `testCreateDocumentToolAndStrictArguments` |
| *(audit)* catalogue réel : schémas, permissions, risques, aucun outil externe | `testToolCatalogDeclaresRealSchemasPermissionsAndRisk` |
| *(audit)* local/cloud : cloud refusé, aucune exécution créée | `testCloudBackendIsPreparedButUnavailable` |
| *(audit)* retour au Brain sans changer son état (pause, refus, annulation) | `testPauseDenialAndCancelAreReportedToBrainWithoutChangingItsState` |
| *(audit)* parent redirigé, dossier remplacé par un lien, canonicalisation sans `realpath` | `testRedirectedParentSymlinkedFolderAndSandboxFriendlyCanonicalPath` |

## Vérifications

Automatiques : suites Swift Package Manager et Xcode (voir le rapport final), scénario Excel avec données fictives, vérification du fichier
exporté par `unzip -t`, `xmllint` et un recalcul indépendant des valeurs (3×2,50 + 2×4,25 + 4×3,10 = 28,40).

Manuelles restantes (non réalisées dans cette session) : ouvrir le `.xlsx` dans Excel ou Numbers ; parcourir l'application réelle
(sélecteur de dossiers, panneau Activité) ; confirmer l'accès aux dossiers sous le vrai App Sandbox.

## Limites et ce qui n'est pas implémenté

- Un seul scénario : CSV/TSV (`produit,quantite,prix_unitaire`) → Excel. Pas de PDF, Word, Excel en entrée, ni d'extraction « intelligente ».
- Pas d'outil de modification, remplacement, déplacement, suppression, envoi, partage ou achat ; pas de cloud ; pas de règle d'autorisation permanente.
- La remise du livrable au demandeur et la validation de l'utilisateur restent des étapes du plan du Brain, non exécutées.
- L'exécution est bornée en mémoire (20 Mo, 100 fichiers, 5 000 lignes) ; `executions.json` est réécrit en entier à chaque checkpoint.
- Les compteurs et checkpoints sont locaux, sans chiffrement applicatif ajouté.

## Audit du 6 novembre 2026

La préparation d'une exécution est maintenant atomique dans le store : des demandes simultanées pour une même mission partagent le même identifiant. Une déclaration sensible est conservée même si l'exécution existe déjà. Un échec peut être annulé afin de préparer une nouvelle exécution. Des régressions supplémentaires vérifient ces cas et l'altération réelle de la sortie avant vérification. Voir [le rapport](AUDIT_2026_11_06.md).
