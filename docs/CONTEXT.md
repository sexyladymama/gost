# GHOST CONTEXT — Mission 003

GHOST CONTEXT est la couche de **mémoire et de compréhension contextuelle**
de GHOST. Elle consomme les événements structurés de GHOST PERCEPTION, les
relie dans un graphe local (personnes, projets, documents, conversations,
demandes, échéances, décisions, préférences) et permet de retrouver, corriger
et supprimer chaque information.

GHOST CONTEXT **comprend et se souvient, mais n'agit pas** : aucune action,
aucun envoi, aucune modification de fichier, aucun accès à une nouvelle source.

## Principes

| Principe | Mise en œuvre |
|----------|---------------|
| Pas de fait inventé | Chaque entité et relation porte un statut `confirmé`, `hypothèse` ou `inconnu`. La répétition ne promeut jamais une hypothèse : seule l'action explicite de l'utilisateur confirme. |
| Preuves | Chaque entité et relation conserve sa provenance (événement, source, empreinte, explication). Sans preuve, elle est supprimée. |
| Cloisonnement | Les sources sont classées *Personnel* / *Professionnel*. Une source non classée reste isolée dans sa propre frontière. Aucune relation ne traverse deux frontières. Données simulées et réelles sont séparées. |
| Autorisation | Chaque ingestion repasse par le `TrustEngine` (contrôle indépendant de Perception). |
| Contrôle utilisateur | Corriger, confirmer, rejeter (ne revient jamais), supprimer, ajouter une information explicite. Une correction survit aux rejeux. |
| Révocation | Révoquer une source supprime la mémoire qui en dérive, sauf choix explicite « conserver ». Après une panne, `reconcilePermissions()` retire la mémoire des sources sans autorisation. |
| Échec sûr | Une base illisible, d'une version plus récente ou d'un autre profil est refusée **sans jamais être effacée**. Les écritures sont transactionnelles (SQLite). |

## Architecture

```
GhostPerception ──(PerceptionEventConsumer)──► ContextEngine (actor)
                                                  │  ContextInference  règles déterministes
                                                  │  ContextRetrieval  synthèses, chronologie
                                                  └─ ContextDatabase   SQLite (context.sqlite)
ContextCenter (@Observable) ◄── updates ── ContextEngine      ──►  vue « Mémoire »
```

- `ContextModel` : types (`ContextNode`, `ContextRelation`, `ContextProvenance`, `ContextSnapshot`…).
- `ContextInference` : règles explicites, sans IA. Marqueurs de projet reconnus :
  `[Projet : Nom]`, `[Project: Name]`, ligne `Projet : Nom`. Un fil e-mail
  sans nom de projet donne un projet de statut *inconnu* (« nom à préciser »).
- `ContextDatabase` : SQLite local, `secure_delete` activé, propriétaire (profil) vérifié, `user_version`.
- `ContextEngine` : sérialise ingestion, corrections et transactions.
- `ContextCenter` : pont observable pour SwiftUI ; les erreurs restent visibles.

## Cas d'ambiguïté

- Plusieurs projets mentionnés par un événement → aucune fusion ; l'ambiguïté est affichée.
- Un chemin de fichier qui correspond à plusieurs projets → association *inconnue*.
- Plusieurs échéances pour une même demande → toutes conservées ; la plus
  récente assertion prévaut ; des échéances simultanées contradictoires sont signalées.
- Le résumé d'un projet liste **ce que GHOST ne sait pas** (périmètre, livrable, échéance, document).

## Interface

Fenêtre « GHOST — Perception » ▸ **Mémoire** : classement des sources,
catégories (Identité, Projets, Contexte, Historique, Demandes), recherche
locale, détail avec « Pourquoi GHOST le sait », liens à confirmer/rejeter,
synthèse de projet et chronologie, ajout manuel, reconstruction depuis les
événements. « Confidentialité ▸ Supprimer les données et la mémoire » efface aussi la mémoire.

## Tests

```bash
swift test --package-path Packages/GhostKit --filter GhostContextTests
```

18 tests (`testC01_` à `testC12_` + cas de robustitude) : entités liées avec
preuves, hypothèses non promues, idempotence, cloisonnement personnel /
professionnel / non classé / simulé, refus sans autorisation, révocation et
conservation, réconciliation après panne, corrections persistantes, rejet
définitif, échéances contradictoires, informations manquantes, rattachement
documentaire et ambiguïté, recherche, suppression totale, persistance,
base corrompue préservée, base d'un autre profil refusée.

## Limites connues

- Pas d'embeddings ni de recherche sémantique : la recherche est lexicale (SQLite `LIKE`).
- Le graphe est entièrement chargé en mémoire et réécrit à chaque transaction ;
  adapté à des milliers d'entités, pas à des millions.
- Non vérifié : comportement avec un compte Gmail réel (seule la simulation est validée).
