# GHOST BRAIN — Mission 004

Cerveau décisionnel de GHOST : il lit les événements de PERCEPTION, les replace dans le contexte de CONTEXT,
décide s'il y a quelque chose à faire, formalise l'objectif, classe la priorité, construit un plan et
crée ou actualise une **mission**.

> **GHOST BRAIN décide et planifie. Il n'exécute rien.** Aucun e-mail envoyé, aucun fichier créé,
> modifié ou supprimé, aucune action externe. `READY` signifie « plan précis, prérequis identifiés » ;
> ce n'est **pas** une autorisation d'agir (`BrainTrust.executionAllowed` renvoie toujours `false`).
> L'exécution relève de la Mission 005 (GHOST AUTONOMY).

## Flux

```
Source autorisée ─► PERCEPTION ─► CONTEXT ─► BRAIN ─► GHOST SHELL (Missions)
   (e-mail, dossier)   événement     graphe     décision   consultation / corrections
                       structuré     local      + mission
```

1. Perception détecte et structure l'événement (titre, résumé, preuves, échéance, candidat mission).
2. Le Brain demande à Context d'intégrer l'événement (idempotent), puis lit le graphe **dans le même
   espace de noms** (personnel / professionnel / simulé ne se mélangent jamais).
3. `DecisionEngine` choisit : `IGNORE`, `MONITOR`, `REMEMBER`, `CLARIFY`, `CREATE_MISSION`,
   `UPDATE_MISSION`, `COMPLETE_MISSION`. Chaque décision conserve éléments utilisés, raisons, confiance,
   alternatives écartées et incertitudes (`DecisionRecord`).
4. `GoalEngine` → `ReasoningEngine` → `PriorityEngine` → `PlanningEngine` → `MissionLifecycle`.
5. Mission, décision et registre d'événements sont écrits **dans une seule transaction atomique**.

## Les moteurs (tous déterministes et testables)

| Moteur | Rôle | Fichier |
|---|---|---|
| Goal | Classe la situation (demande explicite, objectif implicite, obligation, échéance, intention, information, annulation) et formalise l'objectif | `BrainEngines.swift` |
| Decision | Choisit l'une des 7 décisions, dédoublonne, détecte annulation / accusé / changement d'échéance | `BrainDecision.swift` |
| Reasoning | Retrouve les ressources du contexte, détecte manques et contradictions, compare des stratégies | `BrainEngines.swift` |
| Priority | CRITICAL / HIGH / NORMAL / LOW à partir de 6 facteurs pondérés et expliqués | `BrainEngines.swift` |
| Planning | Plan à étapes concrètes, identifiants stables, dépendances, états, permissions, vérifications | `BrainEngines.swift` |
| Uncertainty | « Je sais / je déduis / je suppose / j'ignore », avec provenance et confiance | `BrainEngines.swift` |
| Trust (`BrainTrust`) | Évalue les capacités ; **indépendant de tout modèle** | `BrainEngines.swift` |
| Lifecycle | Création, actualisation, annulation, bonne fin, historique, états valides | `BrainLifecycle.swift` |
| Model Gateway | Fournisseurs de modèles interchangeables, délais, plafonds, journal technique | `ModelGateway.swift`, `ModelAdvisor.swift` |

### Garde-fous contre les missions inutiles

- un message **informatif**, **automatisé**, **en copie** ou de **simple conversation** ne crée jamais de mission ;
- une intention **vague** (« Il faudrait qu'on regarde ça prochainement ») → `MONITOR` + question de clarification, pas de mission ferme ;
- **doublon** (même fil, ou même demandeur et sujet proche) → mise à jour ou `IGNORE`, jamais deux missions ;
- une **annulation** ne vaut que si elle vient du demandeur d'origine ;
- une mission n'est terminée que sur **preuves** (accusé de réception du demandeur, ou fichier conforme avec ≥ 3 indices) ;
- une demande rejetée par l'utilisateur n'est pas recréée (clé supprimée, visible dans l'historique).

### Priorité

`score = Σ poids × valeur` : urgence 0,35 · importance 0,25 · conséquence d'un retard 0,20 · effort vs temps 0,10 ·
relances 0,10 · informations disponibles 0,05. Seuils : ≥ 0,75 CRITICAL, ≥ 0,45 HIGH, ≥ 0,25 NORMAL.
Deux garde-fous : une échéance proche **sans importance ni conséquence** est plafonnée à HIGH ; une obligation à forte
conséquence avec un interlocuteur important est au moins HIGH. L'utilisateur peut imposer sa priorité (la priorité calculée reste visible).

### États d'une mission

`DETECTED → ANALYZING → NEEDS_CLARIFICATION | PROPOSED | BLOCKED → READY → IN_PROGRESS → COMPLETED | CANCELLED | FAILED`.
Les transitions sont validées (`MissionState.canMove`). À la création : `NEEDS_CLARIFICATION` (objectif incomplet ou échéances
contradictoires), `BLOCKED` (données introuvables, agenda absent, source non autorisée), sinon `PROPOSED`. `READY` n'est atteint
qu'après **confirmation de l'utilisateur** et sans blocage. `IN_PROGRESS` n'est jamais atteint dans cette mission.

## Cycle de vie et reprise après panne

- L'identifiant d'une mission est **déterministe** (`hash(clé de dédoublonnage)`) : la même situation donne la même mission.
- Le registre `source|empreinte` garantit qu'un événement n'est analysé qu'une fois ; il est écrit avec la mission.
  Une panne avant l'écriture ne laisse rien de partiel ; la reprise rejoue sans doublon.
- **Pause / arrêt** : le Brain est désactivé (`setActive(false)`) ; les événements arrivés sont comptés (`deferredCount`) mais pas
  traités. À la reprise, `catchUp` rejoue ceux non encore analysés.
- Une échéance **remplacée** reste dans `deadlineClaims` (marquée `superseded`) ; deux sources divergentes → **aucune échéance
  définitive**, mission à clarifier. L'historique n'est jamais réécrit (testé : l'ancien historique est un préfixe du nouveau).
- **Réévaluation** (`reevaluate`) : recalcule priorité, plan et blocages quand le temps passe ou qu'une autorisation est accordée.

## Contrat technique

Types `Codable`, versionnés (`BrainSchema.version = 1`), identifiants stables (étapes : `hash(missionID|clé)`), validation stricte
avant écriture (`MissionLifecycle.validate`, `PlanningEngine.validate`). Le fichier `missions.json` (profil de l'utilisateur) est écrit
atomiquement ; un fichier illisible ou d'une version plus récente n'est **jamais écrasé**. Le Brain ne dépend que de `GhostEvent` et de
`ContextSnapshot`, pas des connecteurs Gmail ou dossier. Compatibilité : aucun format existant n'est modifié ; Perception reçoit trois règles
de preuve supplémentaires et Context une sauvegarde différentielle (voir ci-dessous).

## Model Gateway et modèle externe

- Interface commune `ModelProvider` ; passerelle `ModelGateway` : liste ordonnée (repli), délai, plafonds **200 appels et 200 000 jetons
  par jour**, journal technique **sans contenu**.
- **Fournisseur réel : `AnthropicProvider`** (API Messages, modèle `claude-haiku-5-5` par défaut). **Désactivé par défaut.**
- **Fournisseur simulé : `SimulatedModelProvider`** — règles locales, *jamais* une IA ; réservé aux tests ; toute décision qui l'utilise est
  marquée « SIMULÉ ».
- Le modèle n'est consulté que pour les cas **ambigus** (surveillance, clarification, création peu sûre) et jamais pour un message informatif ou
  automatisé. Il renvoie un JSON validé strictement ; il peut au mieux transformer une surveillance en *clarification* (jamais en mission ferme) ou
  rétrograder une création peu sûre. Il ne touche jamais aux permissions.
- Les textes envoyés sont **masqués** (noms, e-mails, numéros, liens). Le réseau passe par `GuardedHTTPClient` : `api.anthropic.com` n'est joignable
  que pour la source `brain` **et** si l'utilisateur a accordé `callExternalModel` (révocable, journalisé).

### Configuration

1. Fenêtre GHOST ▸ **Missions** ▸ ⚙︎ *Réglages du cerveau*.
2. Coller la clé API Anthropic (stockée dans le Trousseau macOS, jamais dans les fichiers).
3. Activer *Autoriser l'envoi de données masquées à Anthropic*. Le désactiver ou supprimer la clé coupe tout envoi immédiatement.

Sans clé, GHOST BRAIN fonctionne entièrement avec ses règles.

## Interface (GHOST SHELL ▸ Missions)

Liste filtrable (ouvertes, à clarifier, proposées, bloquées, prêtes, terminées), éléments à surveiller, et pour chaque mission : état, priorité,
échéance, phrase d'honnêteté (« Je pense qu'une mission existe, mais il me manque… »), pourquoi elle existe (raisons, éléments utilisés,
alternatives écartées), objectif, ce qui manque, croyances (sais / déduis / suppose / ignore), arbitrage des échéances contradictoires,
facteurs de priorité, plan (états et vérifications), autorisations (accordée / manquante / validation requise), preuves, historique.
Actions : confirmer, signaler incorrecte, corriger l'objectif, préciser, changer la priorité, annuler. Chaque correction est conservée
(`BrainFeedback`) comme donnée d'apprentissage **contrôlée** : aucun entraînement, seulement des règles visibles (ex. demande rejetée).
« Confidentialité ▸ Supprimer les données, la mémoire et les missions » efface aussi les missions.

## Modifications apportées aux autres modules

| Module | Changement | Raison |
|---|---|---|
| Perception | Trois règles de **preuve** : annulation, accusé de réception, changement d'échéance (sans changer la classification) | Le corps des messages n'est pas conservé ; sans ces extraits le Brain ne peut pas voir une annulation |
| Perception | Reconnaissance des **élisions** françaises (« m'envoyer », « l'envoyer ») | Bug : l'action devenait « Répondre à la demande » |
| Perception | Permission `callExternalModel` et règle d'égress `api.anthropic.com` | Réseau filtré et soumis à consentement |
| Context | Sauvegarde **différentielle** et ingestion **idempotente** | Chaque événement réécrivait tout le graphe |
| Context | Correction de `ORDER BY title` (colonne inexistante) dans la recherche | Bug de la Mission 003 |
| Shell | Section Missions, réglages, `BrainAwareCore` (pause/reprise) | Intégration |

## Tests

```bash
swift test --package-path Packages/GhostKit --filter GhostBrainTests
GHOST_BRAIN_EVAL_OUT=docs/BRAIN_EVALUATION.md swift test --package-path Packages/GhostKit --filter BrainEvaluationTests
```

Les tests utilisent des données fictives et **aucune API payante**. Les scénarios A à J de la mission ont chacun un test
(`BrainScenarioTests`) ; `BrainUnitTests` couvre priorité, plans, Trust, passerelle, avis du modèle (parsing strict, plafonds),
réseau filtré, cycle de vie, actions utilisateur, révocation, stockage (fichier corrompu préservé, version future refusée) ;
`BrainEndToEndTests` fait passer la boîte simulée par les vrais Perception → Context → Brain. L'évaluation chiffrée est dans
[BRAIN_EVALUATION.md](BRAIN_EVALUATION.md).

## Performances (mesurées par `BrainPerformanceTests`, machine de développement, Apple Silicon)

| Cas | Résultat mesuré |
|---|---|
| 300 événements en rafale (reprise après pause) | ≈ 3,2 s, ≈ 10,5 ms par événement |
| 150 événements arrivant un par un (150 missions) | ≈ 44 ms en moyenne, pire cas ≈ 80 ms |
| Rejeu de 300 événements déjà analysés | ≈ 6 ms au total (registre) |

Optimisations apportées après mesure : le recalcul de toutes les missions n'a plus lieu à chaque événement (308 ms à 150 missions) mais
une fois par quart d'heure et à la demande ; Context ne réécrit plus tout son graphe (66 → 10 ms par événement en rafale). Le coût par
événement reste **proportionnel à la taille de l'état** (le fichier `missions.json` est réécrit en entier : ≈ 1,8 Mo pour 150 missions) :
adapté à des centaines de missions, pas à des dizaines de milliers (une persistance incrémentale serait alors nécessaire). Appels au modèle :
uniquement pour les cas ambigus, plafonnés à 200 par jour ; aucune boucle d'interrogation continue.

## Honnêteté de l'évaluation

Les 26 scénarios de [BRAIN_EVALUATION.md](BRAIN_EVALUATION.md) ont des résultats attendus écrits **avant** l'exécution, mais ce n'est pas un jeu
indépendant : la première exécution a montré trois écarts, corrigés ensuite — (1) un accusé de réception du demandeur ne terminait pas une mission
`BLOCKED` ; (2) une urgence déclarée (« URGENT… dès que possible ») ne pesait pas assez ; (3) derrière (2), un **vrai bug de Perception** :
« m'envoyer » n'était pas reconnu comme verbe d'action. Les 100 % actuels mesurent donc des règles ajustées sur ces cas ; ils ne prédisent
pas le taux sur des messages réels, et le rappel n'est mesuré que sur 16 cas. Aucun taux n'a été saisi à la main : ils sont calculés à chaque exécution.

## Ce qui est simulé ou non validé

- **Aucune action n'est exécutée** : c'est l'objet de la Mission 005.
- **Modèle réel** : `AnthropicProvider` est testé avec un client HTTP simulé (requête, en-têtes, parsing, erreurs 401/429/5xx, refus réseau sans
  permission). **Il n'a pas été appelé en réel** faute de clé API dans cet environnement.
- **Gmail réel** : toujours non validé (seule la boîte simulée l'est).
- **Agenda** : aucune source d'agenda n'existe ; les demandes de disponibilité sont donc `BLOCKED` (« aucun agenda connecté »).
- Les 26 scénarios d'évaluation ne forment pas un jeu indépendant : deux défauts ont été corrigés après avoir vu leurs écarts (voir le rapport).

## Limites connues

- Le contenu des e-mails n'est pas conservé : le Brain raisonne sur titre, résumé et extraits de preuve de Perception.
- La détection linguistique est lexicale (français / anglais) ; une formulation inhabituelle peut être manquée (aucune mission créée à tort dans
  l'évaluation, mais le rappel n'est mesuré que sur 16 cas).
- Persistance : `missions.json` est réécrit en entier à chaque décision ; le coût croît avec le nombre de missions et de décisions
  (voir les mesures de performance ci-dessous).
