# Audit et corrections — Missions 003 et 004

5 novembre 2026. Base auditée : `9d778d0` (Brain) et `d289385` (Context).
Les changements de cet audit restent locaux, sans commit ni push.

## Résultat

Les 163 tests existants passaient avant correction, avec Swift et Xcode.
Des tests supplémentaires ont reproduit des défauts absents de ces suites.
L'audit a corrigé les problèmes décrits ci-dessous sans ajouter d'exécution
externe ni activer de fournisseur de modèle.

### Analyses devenues périmées

Une analyse attendant l'avis d'un modèle pouvait enregistrer une décision ou
une surveillance après une pause, une révocation ou un effacement. Les tests
utilisent un fournisseur simulé retenu par une barrière asynchrone, appliquent
l'action utilisateur, puis libèrent la réponse. Avant correction, les trois
cas réécrivaient l'état ; après correction, ils ne créent aucune donnée.

Le stockage possède désormais une révision des traitements. Les transactions
vérifient celle qu'avait l'analyse au départ. Pause, révocation, suppression et
écritures concurrentes l'invalident. Les événements sont également revérifiés
auprès du Trust Engine avant leur enregistrement. Le contrôle du registre
est refait dans la transaction pour éviter les doublons simultanés.

Une requête réseau déjà transmise ne peut pas être retirée au fournisseur ;
ce correctif empêche son résultat d'être appliqué à un état invalidé.

### Révocation et effacement des traces

La révocation sans conservation retirait la mission mais laissait des
textes dans les décisions, les corrections utilisateur et les clés de rejet.
Les données dérivées sont maintenant purgées ensemble avec leur registre.
La réconciliation au démarrage considère aussi les événements ayant produit
seulement des décisions, et les sources des ressources connues.

Par prudence, une mission dépendant de la source supprimée est retirée
entièrement : les résumés et historiques n'offrent pas une provenance assez
fine pour retirer seulement certaines phrases. Les dialogues indiquent ce
périmètre. L'option explicite de conservation reste disponible.

### Plafonds du modèle

Les appels étaient comptés après la réponse : deux requêtes concurrentes
ou deux fournisseurs en repli pouvaient dépasser le plafond. La réservation
se fait maintenant avant l'attente et le plafond est revérifié à chaque essai.

Les compteurs techniques (jour, appels, jetons) sont conservés dans
`model-usage.json` par profil. Relancer GHOST ne remet plus le quota à zéro.
Le fichier ne contient ni requête, ni réponse, ni clé. Un suivi illisible ou
non sauvegardable bloque les appels en préservant le fichier existant.

Le plafond de jetons repose sur l'usage connu avant l'appel suivant ; il ne
réserve pas le coût maximal d'une requête en cours. Il ne remplace pas un
plafond de facturation configuré chez le fournisseur. Les compteurs locaux
ne constituent pas un verrou partagé entre plusieurs processus GHOST.

### Documents devenus ambigus

Après une association automatique à `A/rapport.xlsx`, l'apparition de
`B/rapport.xlsx` laissait l'ancien lien actif tout en déclarant l'ambiguïté.
Les associations lexicales sont maintenant recalculées et celles qui n'ont
plus de preuve d'unicité sont rétractées. Les confirmations explicites de
l'utilisateur restent conservées et sont couvertes par un test distinct.

### Cloisonnement des préférences

Le Brain sélectionnait les préférences par préfixe de domaine. Une préférence
professionnelle simulée pouvait donc influencer une situation professionnelle
réelle. Il exige désormais le même espace de noms complet, comme pour les
projets et documents.

### Bonne fin d'une mission

Un nom de fichier, son extension et sa date pouvaient suffire à passer une
mission en COMPLETED, bien que le contenu ne soit jamais lu. Le test a
reproduit cette fausse conclusion. L'arrivée du fichier actualise maintenant
la mission avec un résultat possible à vérifier ; elle ne la termine pas.
La détection d'un accusé de réception du demandeur reste disponible.

## Validation

175 tests : les 163 existants et 12 tests ajoutés par l'audit. Tous les scénarios
utilisent des données fictives ; les fournisseurs de modèles sont simulés.

Résultats finaux : **175/175 avec Swift Package Manager et 175/175 avec le
schéma Xcode**, sans échec. Les 26 scénarios d'évaluation de référence restent
conformes aux attentes existantes. Mesures Swift de ce passage : 300 événements
en 3,11 s, 150 événements séquentiels en 6,94 s, rejeu de 300 événements en
environ 6 ms. Ces mesures sont indicatives et dépendent de la machine.
La compilation Release et la vérification stricte de signature réussissent.
Les entitlements restent limités au sandbox, au réseau sortant, au dossier
sélectionné en lecture seule et à son signet ; aucune autorisation de débogage,
d'écriture des documents ou de capture d'écran n'a été ajoutée.

```sh
swift test --package-path Packages/GhostKit
xcodebuild test -project GhostShell.xcodeproj -scheme GhostShell -configuration Debug -destination 'platform=macOS' -derivedDataPath build
xcodebuild build -project GhostShell.xcodeproj -scheme GhostShell -configuration Release -destination 'platform=macOS' -derivedDataPath build
codesign --verify --strict build/Build/Products/Release/GhostShell.app
codesign -d --entitlements - build/Build/Products/Release/GhostShell.app
git diff --check
```

Les résultats détaillés Xcode sont dans `build/Logs/Test/` (non versionné).
L'évaluation de référence et les mesures de performance font partie de la
suite complète ; elles ne mesurent pas la précision sur des e-mails réels.

Le modèle configuré `claude-haiku-5-5` figure dans la
[documentation officielle Anthropic](https://platform.claude.com/docs/en/models/haiku-5-5/overview),
consultée pendant l'audit. Cela ne valide pas l'accès avec une clé donnée.

## Limites de cette vérification

- Aucun appel Anthropic réel ni connexion Gmail réelle n'a été effectué.
- L'interface compilée n'a pas été pilotée à la souris dans cet audit.
- Linux n'a pas été réexécuté ; validation sur le Mac Apple Silicon et Xcode 26.6.
- Le langage reste interprété par règles ; les scénarios d'évaluation ne sont
  pas un jeu indépendant de validation produit.
- Les données restent locales et sans chiffrement applicatif ajouté.
- La réécriture complète de `missions.json` reste adaptée à un prototype de
  quelques centaines de missions ; ce n'est pas une validation à grande échelle.

Ce rapport décrit un audit ciblé et les corrections vérifiées, pas une
certification de sécurité ni une validation des intégrations réelles.
