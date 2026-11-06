# GHOST VISION — Mission 006

GHOST n'a plus besoin qu'on lui branche une boîte mail : il **regarde l'écran** de l'utilisateur, toutes applications
et pages web confondues, repère ce qu'on lui demande et les rendez-vous, et les transmet au Brain (missions) et à
l'agenda. Décision du fondateur : observation continue, consentement à l'installation, ajout direct à l'agenda.

> **État honnête.** Le pipeline est vérifié de bout en bout avec le vrai OCR d'Apple sur des images générées et un agenda
> simulé. **La vraie capture d'écran (ScreenCaptureKit) et l'écriture dans le vrai agenda (EventKit) n'ont pas été
> exécutées**, car elles exigent des autorisations macOS que seul l'utilisateur peut accorder. Elles sont compilées, mais
> à valider manuellement (voir plus bas).

## Flux

```
fenêtre au premier plan ──► ScreenCaptureKit ──► filtre vie privée ──► OCR local (Vision) ──► blocs de texte
      ──► blocs sans secret ──► « utile ? » (demande adressée à l'utilisateur, ou rendez-vous)
      ├─ oui : ScreenSnapshot ─► Perception (source « Écran ») ─► Contexte ─► Brain ─► mission
      │                                         └──────────────────────────────► CalendarAgent ─► agenda
      └─ non : rien n'est conservé (ni image, ni texte)
```

## Ce qui est lu, et ce qui ne l'est jamais

| Lu | Jamais lu / conservé |
|---|---|
| Le texte de la **fenêtre au premier plan**, toutes les ~3 s si l'écran a changé | Les fenêtres en arrière-plan (un gestionnaire de mots de passe visible à côté n'est pas lu) |
| Chaque bloc (bulle de message, paragraphe) est évalué en mémoire | **Aucune image** n'est écrite ; le texte non utile est oublié immédiatement |
| Un bloc **utile** est conservé : une demande adressée à l'utilisateur ou un rendez-vous | Applications exclues : 1Password, Bitwarden, Dashlane, LastPass, KeePassXC, Trousseau, Mots de passe, réglages système, GHOST |
| | Fenêtres de **banque / paiement / connexion** (par titre) et **navigation privée** |
| | Blocs contenant CVV, IBAN, mot de passe, code de vérification… (ignorés en entier) |
| | Numéros de carte (Luhn), IBAN, clés d'API, jetons, n° de sécurité sociale : masqués |
| | Écran verrouillé ou éteint ; GHOST lui-même au premier plan |

L'utilisateur peut ajouter ses propres applications à exclure (Sources ▸ Écran). **Pause immédiate : ⌃⌥⌘G** depuis
n'importe quelle application (sans permission supplémentaire), ou le bouton Pause. En pause ou arrêt, le moteur de perception
n'interroge plus la source : **aucune capture n'a lieu** (testé). Une pastille « œil » apparaît dans la barre de menus quand
GHOST regarde.

## Consentement

Au premier lancement, GHOST **n'observe rien** tant que l'utilisateur n'a pas accepté (écran « Bienvenue » : deux interrupteurs,
ce que GHOST fait et ne fait jamais). macOS demande ensuite lui-même « Enregistrement de l'écran » et l'accès à l'agenda :
GHOST ne peut ni les accorder ni les contourner. Après avoir accordé l'enregistrement de l'écran, il faut quitter et relancer
GHOST. Tout est désactivable dans Sources ▸ Écran et Agenda.

## Rendez-vous et agenda

`AppointmentExtractor` (règles explicites, sans IA) détecte un événement nommé (dîner, rendez-vous, réunion, soirée, dentiste…)
avec une date. **Ajout direct** à l'agenda seulement si tout est réuni : événement nommé, **date et heure explicites**, ni question
(« dîner le 10 à 21h ? »), ni hypothèse (« peut-être »), ni annulation, ni promotion ; dans le futur (≤ 400 jours) ; interrupteur
« Ajout direct » activé dans GHOST **et** accès complet à l'agenda accordé par macOS. Sinon le rendez-vous est seulement **suggéré**
(Agenda ▸ « Ajouter », avec choix de l'heure si elle manque, ou « Ignorer »). Une échéance (« avant vendredi ») n'est pas un rendez-vous.

Garanties de `CalendarAgent` (testées avec un agenda simulé) :

- **vérification** : l'événement est relu après création ; s'il ne correspond pas, il est retiré ;
- **aucun doublon** : registre persistant (`calendar-actions.json`) et recherche d'un événement équivalent déjà présent ;
- **reprise après panne** : l'intention est journalisée avant l'écriture ; une écriture interrompue retrouve l'événement déjà créé ;
- **annulation en un clic** (Agenda ▸ « Annuler l'ajout ») : GHOST ne supprime **que** l'événement qu'il a créé (identifiant du registre) ;
  les événements de l'utilisateur ne sont jamais modifiés ni supprimés ;
- chaque événement porte une note : « Ajouté par GHOST d'après un message vu dans … » avec l'extrait.

## Missions depuis l'écran

Le texte d'un bloc passe par le même moteur de compréhension que les e-mails, avec un **seuil plus strict** (75 % au lieu de 60 %) :
une simple formule de politesse sur une page web (« please subscribe ») ne devient pas une mission (testé). La mission créée affiche
« Vu dans WhatsApp » et reste une **proposition** (rien n'est exécuté sans validation, comme avant).

## Décisions d'architecture

1. **Capture + OCR local plutôt qu'API d'accessibilité.** L'accessibilité donnerait un texte plus exact mais macOS l'interdit aux
   applications en bac à sable : il aurait fallu retirer le bac à sable de GHOST. Le bac à sable est conservé.
2. **Fenêtre au premier plan seulement.** Plus sûr (le filtre de vie privée s'applique à l'application réellement lue) et moins coûteux.
   Limite : deux fenêtres côte à côte ne sont lues que l'une après l'autre, quand elles passent au premier plan.
3. **Seuls les blocs utiles deviennent des événements.** Sans cela, `events.json` se remplirait de texte d'écran.
4. **Entitlement ajouté** : `com.apple.security.personal-information.calendars` (EventKit). Textes d'autorisation dans l'Info.plist.

## Tests

`swift test --package-path Packages/GhostKit --filter GhostVisionTests` : filtre de vie privée (applications, fenêtres, secrets,
mots entiers), regroupement en blocs, extraction de rendez-vous (certain / question / hypothèse / sans heure / promotion / annulation / échéance),
**vrai OCR d'Apple** sur une image générée (accents français compris), source écran (blocs utiles, dédoublonnage, applications exclues jamais lues,
secrets, formules de politesse, autorisation requise), agent d'agenda (ajout vérifié, doublons, suggestions, passé, annulation sélective,
vérification échouée, panne après création, registre persistant et corrompu), bout en bout (écran → Perception → Contexte → Brain **et** agenda,
pause), et vraie capture sans permission = rien.

## Vérifications manuelles à faire

1. Lancer GHOST, accepter l'écran de consentement, accorder « Enregistrement de l'écran » dans Réglages Système, relancer GHOST.
2. Afficher un message contenant « On a un dîner le 10 novembre à 21h » : l'événement apparaît dans Calendrier, et dans GHOST ▸ Agenda.
3. Afficher « Peux-tu me préparer un fichier Excel pour demain matin ? » : une mission apparaît dans GHOST ▸ Missions.
4. Vérifier ⌃⌥⌘G (pause), « Annuler l'ajout », et qu'une fenêtre de navigation privée ou 1Password n'est jamais lue.

## Limites connues

- Non vérifié en réel : ScreenCaptureKit, EventKit, invites macOS, raccourci global, écran de consentement.
- Le texte lu peut être celui que l'utilisateur écrit lui-même (zone de saisie) : un faux positif est possible ; les missions restent des propositions.
- OCR : dépend de la lisibilité (petit corps, faible contraste) ; l'extraction est lexicale (français et anglais).
- Le titre de fenêtre sert à détecter banque et navigation privée : une page sensible au titre neutre n'est pas reconnue. D'où la liste d'exclusions
  personnalisable.
- L'accès à l'agenda demande l'accès **complet** (nécessaire pour vérifier et éviter les doublons).
- Les titres de fenêtre et extraits de 160 caractères sont conservés localement dans les événements, sans chiffrement applicatif ajouté.

## Audit du 6 novembre 2026

La capture réelle sélectionne la première fenêtre de l'application dans l'ordre de superposition, sans choisir une autre fenêtre parce qu'elle est plus grande. Les exclusions sont contrôlées avant capture puis avant OCR. Ce choix est testé sur des listes fictives ; le parcours réel reste à vérifier.

Chaque nouvel ajout agenda porte un marqueur unique enregistré avant écriture. La reprise n'adopte que les événements portant ce marqueur ; un ajout interrompu sans preuve devient une suggestion à confirmer. L'annulation refuse un événement dont la provenance a disparu, y compris les anciens ajouts sans marqueur. La vérification porte aussi sur l'heure de fin. Pause et révocation sont recontrôlées avant l'écriture ; un ajout déjà engagé peut finir. Voir [le rapport d'audit](AUDIT_2026_11_06.md).
