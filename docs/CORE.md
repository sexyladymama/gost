# GHOST CORE — Mission 008

## Phase A : audit vérifié

État initial : branche `claude/focused-rubin-wirgeh`, commit `05abd89`, arbre propre et synchronisé avec GitHub. Xcode 26.6 / Swift 6.3.3. Suite de référence exécutée : 293 tests, 4 ignorés, aucun échec (SwiftPM, 6 novembre 2026).

| Capacité | Sources réelles | Comportement actuel | Nature | Manque / évolution |
|---|---|---|---|---|
| Observations autorisées | GhostPerception/Engine, Connectors | Gmail, dossiers, écran → événements | règles et connecteurs réels ; tests avec doublures | consommer sélectivement les missions du Brain |
| Mémoire | GhostContext/ContextEngine, ContextDatabase, ContextRetrieval | SQLite, preuves, corrections, espaces séparés | déterministe | assemblage contextuel borné pour un objectif |
| Décisions / missions | GhostBrain/BrainEngine, BrainDecision, BrainLifecycle | règles de priorité et cycle de vie ; avis modèle sur ambiguïtés | règles + modèle externe facultatif | conserver une identité canonique et y rattacher les sessions Core |
| Passerelle | GhostBrain/ModelGateway | Anthropic Messages, quotas, délai, journal | vrai client ; tests HTTP simulés | décrire capacités, disponibilité et acheminer aussi le modèle Apple |
| Modèle Apple | GhostMind/LanguageModel | FoundationModels sur macOS 26, voie séparée de la passerelle | vrai adaptateur ; disponibilité dépendante du Mac | passer par ModelGateway pour Brain, Mind et Core |
| Mind | GhostMind/MindEngine | règles de sélection mail/recherche/logo/document ; rédaction par modèle | choix déterministe, génération locale/externe | exposer les capacités à la boucle sans recréer les outils |
| Exécution | GhostAutonomy/ExecutionEngine, ToolEngine, ExecutionTrust | CSV/TSV → XLSX, checkpoints, permissions par exécution | réel, workflow fixe | accès documentaire typé sous le même ExecutionTrust |
| Vision / agenda | GhostVision, PerceptionController | OCR local, événements, ajouts avec provenance | OCR réel sur images de test ; agenda simulé | conserver opt-in, exclusions et pause ; aucune nouvelle capture Core |
| Orchestration | aucune boucle centrale à ce stade | pas de retour outil → modèle ni adaptation dynamique | absente | nouvelle bibliothèque GhostCore |
| Interface | GhostShell/UI | missions et panneaux de résultats ; pas d'objectif libre central | SwiftUI | entrée d'objectif, plan, décisions, approbations et état IA |

### Réponses aux questions d'audit

1. Fournisseurs implémentés : Apple FoundationModels et Anthropic Messages ; simulateur explicitement marqué pour les tests. Aucun fournisseur OpenAI.
2. Aucun succès API Anthropic réel prouvé par cet audit. Les anciens essais de modèle Apple sont conditionnels ; ils ne prouvent pas sa disponibilité actuelle.
3. Mind essaie Apple directement puis GatewayLanguageModel/Anthropic.
4. Brain utilise ModelGateway/Anthropic seulement pour certains avis d'ambiguïté.
5. Deux voies existent donc initialement ; elles seront réunies derrière ModelGateway.
6. Le modèle ne reçoit pas d'assemblage personnel général : petits champs Brain ou demande Mind ; le destinataire est retrouvé localement.
7–10. Pas de demande d'outil dynamique, de boucle multi-outils, de retour de résultat ni de révision de plan par modèle.
11. Autonomy reprend son scénario Excel fixe ; Mind ne possède pas cette reprise générale.
12. Brain crée proactivement des missions à partir d'événements autorisés, avec registre anti-doublon.
13. Les décisions restent principalement déterministes.
14. Les fournisseurs et réponses de test sont marqués simulés ; un résultat de test simulé ne valide pas une API réelle.
15. Brain planifie, Mind choisit des capacités par règles, Autonomy possède un second plan fixe. Core doit coordonner ces responsabilités, pas ajouter une deuxième base de connaissances ni une deuxième identité de mission.

## Architecture cible et migration

- `ModelGateway` commun, fournisseurs déclarant texte / protocole structuré / interaction multi-tour compatible. Aucun appel natif d'outils revendiqué si non implémenté.
- `GhostCore` dépend des modules existants ; une `AgentSession` est un journal d'exécution rattaché à une mission Brain, pas une seconde mission.
- Le modèle choisit dynamiquement une décision JSON versionnée. Le catalogue et le dispatcher appliquent les schémas et les permissions ; les résultats bornés sont renvoyés au modèle.
- Lecture et sauvegarde passent par `ExecutionTrust`. La mémoire demeure dans GhostContext. Une proposition de préférence exige une confirmation utilisateur avant persistance.
- Les événements ne déclenchent pas automatiquement une diffusion distante. Les demandes directes utilisent le même cycle de vie Brain. Les anciens workflows restent utilisables durant la migration.
- Risques : ambiguïté de l'objectif, hallucination du modèle, reprise après écriture, appels lents, révocation pendant une réponse, exposition de contexte, doubles traitements. Des limites, reçus, contrôles de génération et tests doivent couvrir ces cas avant publication des phases suivantes.

## Validation à venir

La phase A ne constitue pas une validation de l'agent. Les phases B à G doivent implémenter et tester les capacités puis distinguer explicitement essais simulés, modèle réel, services externes et parcours UI manuel.

Sources primaires consultées pour la compatibilité : [API et modèles Anthropic](https://platform.claude.com/docs/en/models/overview), [Foundation Models Apple](https://developer.apple.com/documentation/FoundationModels/generating-content-and-performing-tasks-with-foundation-models).

## Phase B : passerelle commune

`ModelProvider` déclare sa localisation, sa disponibilité et les capacités réellement exposées par l'adaptateur. `structuredProtocol` et `multiTurnProtocol` désignent une compatibilité JSON et retour de résultats gérée par GHOST, pas un appel d'outil natif du fournisseur. Les requêtes choisissent local uniquement, externe uniquement ou local avec repli autorisé. Les modèles simulés restent identifiés dans les réponses.

`OnDeviceModelProvider` adapte FoundationModels à `ModelGateway`. Mind peut utiliser les adaptateurs local/externe de cette même passerelle ; le raccordement dans la composition sera effectué avec Core. Les limites de taille, l'annulation avant repli et un délai qui n'attend pas un SDK non coopératif sont testés. La réponse tardive d'un fournisseur est abandonnée.

Validation de cette phase : 17 tests de passerelle exécutés sans échec (`swift test --package-path Packages/GhostKit --filter 'SharedGatewayTests|ModelGatewayTests'`). Cela ne valide pas encore un appel au modèle réel.

## Phases C à F : GHOST CORE (6 novembre 2026)

### Ce qui existe

| Composant | Fichier | Rôle |
|---|---|---|
| Protocole de décision | `GhostCore/AgentModel.swift` | `AgentDecision` versionné ; décodage strict (champ, outil, mission, taille) après une réparation déterministe des écarts bénins d'un petit modèle |
| Registre d'outils | `GhostCore/ToolRegistry.swift` | 16 outils déclarés ; 3 explicitement **indisponibles** (présentation, tableur via Core, rien de simulé) |
| Boîte à outils | `GhostCore/CoreTools.swift` | exécute les outils réels : mémoire, fichiers autorisés, création vérifiée par relecture, brouillon (Mind), recherche web / lieux, visuel SVG validé, propositions de préférence |
| Coordinateur et boucle | `GhostCore/CoreCoordinator.swift` | boucle bornée, approbations, reprise, pause, annulation, suppression |
| Checkpoints | `GhostCore/AgentStore.swift` | `core.json` (exécution seulement ; la mémoire reste dans GhostContext, l'identité de mission dans Brain) |
| Interface | `GhostShell/UI/ObjectivesView.swift`, `GhostCore/CoreCenter.swift` | saisie d'un objectif, plan, reçus d'outils, accord, question, résultat à relire, état des IA |
| Brain | `BrainEngine.submitObjective / recordCoreActivity / acceptCoreResult` | **une seule identité de mission** : un objectif crée la mission canonique ; une réponse du modèle ne la termine jamais, seul « Je l'ai relu » le fait |
| Mind | `MindEngine.prepareDraft` | brouillon pour Core, jamais envoyé ; l'envoi reste `send(_:confirmedByUser:)` |

### La boucle

objectif → mission Brain → (contexte sélectif de **cette** mission + outils réellement disponibles + historique des appels) → décision JSON → validation → autorisation → outil → résultat renvoyé au modèle (comme **donnée**) → … → réponse finale à relire.
Limites : 16 itérations, 10 outils, 80 000 jetons, 2 $ (modèles externes seulement), 180 s, 3 appels identiques = boucle, 1 relance de protocole. Un modèle local ne consomme pas le budget financier.

### Sécurité (outre la confiance existante)

- L'outil n'est proposé au modèle que s'il est disponible **et** autorisé (recherche en ligne, dossier choisi) ; l'appel est de nouveau refusé à l'exécution.
- Envoi : approbation liée à l'**empreinte de l'action** (outil, mission, arguments **et** contenu exact du brouillon) ; modifier le brouillon, un argument ou rejouer l'accord le rend invalide ; jamais deux envois.
- Fichiers : un seul dossier, aucun lien symbolique suivi, aucun chemin hors du dossier, jamais d'écrasement, relecture réelle après création.
- Reprise : une lecture interrompue est refaite ; une écriture interrompue (effet inconnu) est **bloquée**, jamais rejouée.
- Pause, annulation et suppression : une réponse tardive du modèle est ignorée (testé) ; on ne ressuscite ni une mission annulée ni une mémoire effacée.
- Mémoire : le modèle **propose**, une règle déterministe filtre les sujets sensibles, l'utilisateur confirme avant qu'une préférence entre dans GhostContext (confirmée, fournie par l'utilisateur).
- Un document, un site ou un fichier lus peuvent contenir des consignes : ce sont des données ; testé avec un fichier piégé (rien n'est envoyé).

### Validation : ce qui est prouvé et ce qui ne l'est pas

| Niveau | Résultat |
|---|---|
| Tests unitaires et scénarios avec un fournisseur **simulé** (20 tests Core) | briefing dynamique (mémoire → documents → création → vérification), adaptation à un résultat vide, question de clarification puis reprise, accord pour un envoi, refus, reprise après redémarrage, boucles, limites, annulation tardive, pause, suppression, recherche refusée, fichier piégé, chemins et liens, propositions de mémoire |
| Modèle **réel** Apple (sur ce Mac, `GHOST_LIVE=1`) | la **structure** est garantie (génération guidée Apple) ; `search_memory` s'est exécuté réellement ; mais le modèle de ~3 milliards de paramètres **ne mène pas encore un scénario complet** : il oublie des étapes, se trompe d'arguments, pose des questions inutiles. Résultat variable d'un essai à l'autre. |
| Modèle externe (Anthropic) | **jamais testé** : aucune clé n'est configurée ; aucun appel réel n'a été fait |
| Interface | compile ; **non vérifiée à la main** |
| Services réels (Apple Plans, DuckDuckGo) | vérifiés pendant la Mission 007, pas via Core |

Conséquence honnête : l'architecture d'agent est en place et sûre, mais **la qualité du raisonnement dépend du modèle**. Pour des missions complexes, un modèle externe plus capable est nécessaire ; il passera par la même passerelle avec masquage des adresses e-mail et uniquement si l'utilisateur l'active.

### Limites connues

- Tableur et présentation : indisponibles via Core (le scénario Excel d'Autonomy reste lancé depuis sa propre mission).
- OpenAI : non implémenté (la passerelle accepte un fournisseur de plus sans changer Core).
- La confidentialité externe masque les adresses e-mail, pas tous les noms.
- Pas d'apprentissage automatique depuis les corrections : seules les préférences proposées par le modèle puis confirmées sont retenues.
- Pas de déclenchement proactif d'une session Core à partir d'un événement : Brain crée toujours les missions proactives, Core ne démarre que sur un objectif saisi.
