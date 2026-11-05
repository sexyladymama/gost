# GHOST MIND — Mission 007

GHOST ne se contente plus de repérer une demande : il **la comprend et fait le travail**, avec sa propre intelligence.
À partir d'une mission du Brain (qui peut venir d'un message lu à l'écran), `GhostMind` détermine ce qui est demandé et le réalise.

| Demande vue à l'écran | Ce que fait GHOST | Où le voir |
|---|---|---|
| « Écris un mail à Paul pour décaler jeudi » | Retrouve Paul dans la mémoire locale, rédige le mail | **Brouillons** : *Envoyer* / *Refaire* / *Annuler* |
| « Trouve un club de boxe vers chez nous genre le 17 », « Regarde les bars vers La Défense » | Cherche des lieux réels (Apple Plans) autour de la zone | **Recherches** |
| « Crée un logo pour la boîte » | Dessine un SVG, le contrôle, le rend en PNG, l'enregistre | **Créations** |
| « Rédige une lettre de motivation… » | Rédige le document (RTF) et l'enregistre | **Créations** |
| « On a un dîner le 10 novembre à 21h » | Ajoute à l'agenda (Mission 006) | **Agenda** |

## Principe de sécurité

- **Autonome sur ce qui reste chez soi** : rédiger un brouillon, chercher, créer un fichier dans le dossier choisi.
- **Jamais autonome sur ce qui engage l'utilisateur** : un mail ne part que sur le clic *Envoyer*
  (`MindEngine.send(_:confirmedByUser:)` refuse sans cette confirmation ; aucune autre voie d'envoi n'existe). Jamais deux fois,
  jamais rejoué après une interruption (l'intention est notée avant l'envoi ; un envoi « en cours » à la relance devient « à vérifier »).
- Un brouillon, une recherche ou une création n'est jamais refait en double pour la même mission.
- Rien n'est inventé : sans modèle de langage, GHOST le dit (brouillon simplifié clairement signalé, ou « modèle requis ») au lieu de fabriquer.

## L'intelligence

`LanguageModel` est une interface ; GHOST essaie dans l'ordre :

1. **Apple Intelligence (modèle intégré à macOS 26, `FoundationModels`)** — tourne **sur le Mac**, sans clé, sans réseau.
2. **Modèle externe** (Anthropic, avec votre clé et votre consentement) — seulement s'il est activé ; **noms, prénoms et adresses sont remplacés
   par des jetons avant l'envoi puis restaurés localement** (`ReversibleMask`).

> **État sur ce Mac (vérifié le 5 novembre 2026)** : le modèle d'Apple est **désactivé** (`appleIntelligenceNotEnabled`).
> Tant qu'il ne l'est pas, GHOST ne peut ni rédiger ni dessiner. À activer dans **Réglages Système ▸ Apple Intelligence et Siri**
> (téléchargement de quelques Go ; le modèle reste sur le Mac). GHOST affiche cette consigne dans *Brouillons* et propose *Refaire* une fois activé.

La compréhension de la demande (`IntentClassifier`), la recherche de lieux et l'ajout à l'agenda **ne dépendent pas** du modèle et fonctionnent déjà.

## Outils

**Mail.** Destinataire retrouvé parmi les personnes déjà vues (une seule correspondance avec adresse, sinon GHOST demande — jamais de devinette).
Réponse du modèle validée strictement (JSON, objet 3–140 caractères, texte 10–4 000, pas de gabarit non rempli). Envoi par l'application Mail
(vos comptes, votre signature) via AppleScript ; macOS demande une fois l'autorisation d'automatisation ; entitlement limité à `com.apple.mail`.
Le journal d'accès ne garde que le **domaine** du destinataire.

**Recherche de lieux.** Apple Plans (MapKit), sans clé ni compte : la zone est localisée, puis la recherche est menée dans un rayon de 4 km, triée par
distance. Seules la question (« club de boxe ») et la zone (« La Défense ») sont envoyées. « Chez nous » utilise le quartier ou la ville saisis dans
**Sources ▸ Recherche** (reste sur le Mac) ; sans cela GHOST demande. Soumise à l'autorisation `searchOnline` (écran de bienvenue / Sources).
Vérifié une fois contre le vrai service : « La Grande Arche de la Défense » localisée, 25 bars renvoyés avec noms et adresses.

**Création.** Dossier choisi une fois par l'utilisateur (accès macOS par signet) — le seul où GHOST écrit. Écriture en `O_EXCL` : jamais d'écrasement
(« Logo (2).svg »), noms assainis, aucune sortie du dossier. Logo : SVG extrait de la réponse puis refusé s'il contient script, lien externe, image,
entité XML, s'il est trop gros ou trop complexe, ou sans dimensions sur l'élément `<svg>` ; il est ensuite **rendu par macOS** et refusé s'il est vide ou
uni. Document : Markdown mis en forme en RTF (lisible dans TextEdit, Pages, Word).

## Perception : demandes à l'impératif

Les messages courants (« écris… », « trouve… », « regarde… », « crée… ») sont reconnus comme demandes. Pour le texte lu à l'écran, le seuil est plus strict
(75 %) et les libellés d'interface ambigus (« Recherche avancée », « Commande n°1234 », « Note importante ») ne déclenchent rien (testé).

## Tests

`swift test --package-path Packages/GhostKit --filter GhostMindTests` (39 tests) : compréhension de vos exemples, masquage réversible, validation du modèle,
brouillons (modèle indisponible, externe masqué, réponse invalide, repli), envoi (clic obligatoire, une seule fois, échec, interruption, fichier corrompu
préservé), recherche (zone, « chez nous », autorisation, échec, doublon), création (logo validé et rendu, document RTF, sans modèle, sans dossier, SVG dangereux,
masquage), et un **bout en bout** : une demande lue à l'écran (vrai OCR) → Perception → Contexte → Brain → brouillon prêt, sans envoi automatique.

## Ce qui n'est pas validé

- **Le modèle d'Apple n'a jamais répondu sur ce Mac** (désactivé) : la qualité réelle des mails, documents et logos est inconnue. Les tests utilisent un modèle scripté, toujours signalé « SIMULÉ ».
- **L'envoi réel par Mail** (AppleScript, invite d'automatisation) et l'interface (Brouillons, Recherches, Créations) n'ont pas été exécutés : à vérifier à la main.
- Un logo dessiné par un petit modèle local peut être médiocre : il est contrôlé (valide, non vide) mais pas jugé esthétiquement ; *Refaire* produit une nouvelle version.

## Limites et suite

- **Recherche web générale** (autre chose que des lieux) : non implémentée — aucune source gratuite et fiable sans clé ; nécessite un choix de fournisseur.
- **Images** autres que des logos vectoriels : non implémentées (génération d'images par un service externe, ou Image Playground).
- WhatsApp, Messages : GHOST rédige le texte mais ne sait envoyer que par Mail.
- Réservations, achats, publications : jamais, sans validation explicite (niveau 3).
