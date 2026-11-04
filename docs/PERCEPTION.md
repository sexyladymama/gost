# GHOST PERCEPTION — documentation technique (Mission 002)

GHOST PERCEPTION est le premier moteur de perception de GHOST. Il **perçoit,
comprend et transmet** des événements structurés issus de sources que
l'utilisateur a explicitement autorisées. Il n'exécute aucune action.

## 1. Vue d'ensemble

```
            ┌──────────────── TrustEngine ────────────────┐
            │ autorisations · périmètre dossier · journal  │
            └───────▲──────────────────▲───────────────────┘
                    │ require()         │ isAuthorized()
┌─────────────┐  poll()  ┌──────────────┴───┐   ┌────────────────┐   ┌─────────────────────┐   ┌────────────┐
│ EmailSource │─────────▶│                  │──▶│ EventNormalizer│──▶│ UnderstandingEngine │──▶│ EventStore │
│ FolderSource│─────────▶│ PerceptionEngine │   └────────────────┘   │  + DeadlineExtractor│   │ (dédoublon-│
└──────┬──────┘          │  (boucle, pause, │                        └─────────────────────┘   │  nage)     │
       │                 │   erreurs)       │──── AsyncStream<PerceptionUpdate> ───┐          └────────────┘
       │                 └──────────────────┘                                      ▼
┌──────▼───────────────┐                                              ┌───────────────────────┐
│ MailProvider         │   GuardedHTTPClient (seul accès réseau)       │ PerceptionCenter      │
│ · GmailMailProvider ─┼──▶ gmail.googleapis.com, oauth2.googleapis.com│ (GhostCoreInterface,  │
│ · SimulatedMail…     │                                              │  @Observable) ──▶ UI  │
└──────────────────────┘                                              └───────────────────────┘
```

Code : `Packages/GhostKit/Sources/GhostPerception/` (aucune dépendance externe,
aucun code d'interface ; compilable et testable sous macOS et Linux).

| Composant demandé      | Implémentation |
|------------------------|----------------|
| Perception Engine      | `Engine/PerceptionEngine.swift` |
| Source Connectors      | `Connectors/PerceptionSource.swift`, `Connectors/Email/*`, `Connectors/Folder/*` |
| Event Normalizer       | `Normalizer/EventNormalizer.swift` |
| Understanding Engine   | `Understanding/UnderstandingEngine.swift`, `Understanding/DeadlineExtractor.swift` |
| Event Store            | `Store/EventStore.swift` (`FileEventStore`) |
| Trust Engine           | `Trust/TrustEngine.swift`, `Trust/AccessLog.swift`, `Networking/HTTPClient.swift` (`GuardedHTTPClient`) |
| GhostCoreInterface     | `Engine/PerceptionCenter.swift` (implémente le protocole de la Mission 001) |
| Assemblage par profil  | `Engine/PerceptionSystem.swift`, `Profile/GhostProfile.swift` |

## 2. Cycle de collecte

`PerceptionEngine` exécute une boucle (1 tick/s par défaut). À chaque tick,
pour chaque source **activée** dont l'intervalle est écoulé :

1. la source vérifie son autorisation auprès du `TrustEngine` (sinon : refus journalisé) ;
2. `poll()` renvoie des `RawObservation` (e-mail ou changement de fichier) ;
3. `EventNormalizer` produit une `NormalizedObservation` (format commun) ;
4. si l'empreinte est déjà connue, l'observation est ignorée ;
5. `UnderstandingEngine` produit un `GhostEvent` ;
6. `EventStore.insert` ne conserve que les événements nouveaux ;
7. les nouveaux événements sont diffusés à l'interface (`PerceptionUpdate.newEvents`)
   et aux futurs moteurs (`PerceptionEventConsumer`).

Intervalles : simulation 20 s, Gmail 60 s, dossier 5 s. En cas d'erreur,
attente exponentielle (×2, ×4… jusqu'à ×32), puis retour à la normale au
premier succès.

### Pause et arrêt — garanties

- `ACTIVE → PAUSED` (bouton « Mettre en pause ») et `→ STOPPED` (« Arrêter la
  perception ») annulent la boucle ; `runCycle` vérifie l'état avant **chaque**
  source et ne fait rien hors de l'état `running`, y compris pour la collecte
  manuelle « Collecter maintenant ».
- `pause()`/`stop()` attendent la fin d'un éventuel cycle en cours : à leur
  retour, plus aucune collecte n'est active.
- Les commandes de l'interface passent par une file unique (`PerceptionCenter`),
  ce qui garantit leur ordre (pause → reprise jamais inversées).
- Désactiver une source l'exclut des cycles. Révoquer une source révoque
  l'accès externe (jeton Google), retire l'autorisation et la source.

## 3. Sources

### 3.1 E-mail (`EmailSource` + `MailProvider`)

Contrat `MailProvider` : lecture seule. Aucune méthode d'envoi, de suppression
ou de modification n'existe dans le code.

- **`GmailMailProvider`** (réel) — API REST Gmail v1 :
  - `GET /gmail/v1/users/me/profile` (adresse du compte) ;
  - `GET /gmail/v1/users/me/messages?q=in:inbox after:<epoch>` (nouveaux messages) ;
  - `GET /gmail/v1/users/me/messages/{id}?format=full`.
  - Données conservées : `From`, `To`, `Cc`, `Subject`, date, indices d'envoi
    automatisé (`List-Unsubscribe`, `Precedence`, `Auto-Submitted`),
    `In-Reply-To`, partie `text/plain` tronquée à 8 000 caractères. Tout le
    reste (autres en-têtes, HTML, pièces jointes) est ignoré à la lecture.
  - Le premier curseur est la date de connexion : les e-mails antérieurs ne sont
    pas parcourus.
- **OAuth** (`GoogleOAuthClient`, `OAuthTokenProvider`) : flux *Authorization
  Code + PKCE (S256)* pour application native (RFC 8252/7636), `state` vérifié,
  portée **`gmail.readonly`** uniquement, session d'authentification éphémère
  (`ASWebAuthenticationSession`). Jetons stockés dans le **Trousseau**
  (`KeychainSecretStore`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`),
  renouvelés automatiquement, révoqués auprès de Google lors de la révocation
  (le jeton local est effacé même si Google est injoignable).
- **`SimulatedMailProvider`** (simulation) — 7 e-mails réalistes livrés un par
  un, à raison d'un par collecte. Les événements sont marqués `isSimulated` et
  affichés avec le badge **SIMULATION**. Aucun accès réseau.

### 3.2 Dossier (`FolderSource`)

- Dossier choisi par l'utilisateur dans le sélecteur macOS (seul moyen d'y
  accéder dans le bac à sable), mémorisé par un signet en **lecture seule**.
- Parcours récursif limité (profondeur 4, 5 000 éléments). Chaque sous-dossier
  est revérifié par le `TrustEngine` avant ouverture. Les liens symboliques ne
  sont jamais suivis ; fichiers cachés et temporaires ignorés ; paquets
  (`.pages`, `.app`…) traités comme un seul document.
- Détection par comparaison d'instantanés : créé / modifié (taille ou date) /
  supprimé. Le premier parcours sert de référence.
- **Seules les métadonnées** sont lues (`FileSystemReader` n'offre aucune
  méthode de lecture de contenu, d'écriture ni de suppression).

### 3.3 Ajouter une source

1. Créer un type conforme à `PerceptionSource` (`poll()`, `revokeAccess()`, `resetState()`).
2. Ajouter une `Permission` et vérifier `trust.require(...)` au début de `poll()`.
3. Produire des `RawObservation` (ajouter un cas si nécessaire) et l'étendre dans
   `EventNormalizer`.
4. Si la source utilise le réseau, ajouter une `EgressRule` explicite.
5. L'enregistrer via `PerceptionCenter.register(_:)`.

Calendrier, navigateur, messageries, etc. ne sont **pas** implémentés.

## 4. Compréhension

`UnderstandingEngine` repose sur des **règles linguistiques explicites**
(français et anglais) — ce n'est pas un modèle d'IA. Chaque règle déclenchée
est ajoutée à `GhostEvent.evidence` ; l'interface l'affiche dans « Pourquoi
GHOST l'a détecté ».

| Type | Déclencheurs principaux |
|------|-------------------------|
| `REQUEST` | « peux-tu », « pourriez-vous », « merci de… », « j'aurais besoin », « could you », « please »… ; question à la 2ᵉ personne |
| `TASK` | demande + verbe d'action (préparer, envoyer, rédiger, relire, valider, send, review…) |
| `DEADLINE` | échéance extraite (voir ci-dessous) |
| `FOLLOW_UP` | « relance », « as-tu pu », « je reviens vers toi », « any update »… ou objet « Relance/Rappel » |
| `INFORMATION` | envoi automatisé, adresse no-reply, « pour info », « FYI », désabonnement… ou absence de signal |
| `CONVERSATION` | réponse dans un fil sans demande, message court de remerciement |
| `DOCUMENT_EVENT` | changement observé dans le dossier autorisé |

Le texte cité (`> …`, « Le … a écrit : ») et les signatures (`-- `) sont retirés
avant analyse : une demande citée d'un ancien message n'est pas réinterprétée.

**Extraction** : action attendue (proposition à partir du verbe d'action, sans
l'échéance ni les formules de politesse), résultat attendu (Excel, rapport,
présentation, devis…), informations nécessaires (« avec / contenant / incluant
… »), personnes (expéditeur, destinataires, copie).

**Échéances** (`DeadlineExtractor`) : demain/après-demain (+ matin/midi/
après-midi/soir), jours de la semaine (prochaine occurrence), dates
(« 15 novembre », « 20/11 », ISO, « December 3rd »), heures (« à 14h »,
« avant 17h »), « fin de journée/semaine/mois », « semaine prochaine »,
« dans 3 jours ». Calculées par rapport à la date de l'e-mail. Conventions :
matin 9 h, midi 12 h, après-midi 14 h, soir 18 h, jour seul 18 h. Une échéance
précédée d'un marqueur (« pour », « avant », « d'ici », « by »…) est préférée.

**Confiance** : score additif (base 0,30 ; demande +0,30 ; question +0,20 ;
verbe d'action +0,15 ; relance +0,15 ; livrable +0,10 ; échéance +0,10 ou +0,05 ;
destinataire direct +0,05 ; automatisé −0,40 ; marqueur informatif −0,20 ;
en copie seulement −0,20), borné à [0,05 ; 0,99].

**Candidat mission** (`isMissionCandidate`) seulement si : demande, tâche ou
relance ; type principal ≠ information ; message non automatisé ; utilisateur
pas uniquement en copie ; confiance ≥ 0,60. GHOST **ne crée aucune mission** :
il marque l'événement pour les futurs moteurs.

## 5. Format d'événement (`GhostEvent`, schéma v1)

| Champ | Description |
|-------|-------------|
| `id` | UUID unique |
| `fingerprint` | `source:identifiantExterne:version` — clé de dédoublonnage |
| `schemaVersion` | `1` |
| `kind`, `tags` | type principal et toutes les catégories détectées |
| `summary`, `title` | résumé généré, objet/nom de fichier |
| `source` | `{id, kind, displayName, isSimulated}` |
| `detectedAt`, `occurredAt` | date de détection, date de l'événement d'origine |
| `people` | `[{name, email, role}]` |
| `expectedAction`, `expectedOutput`, `requiredInformation` | ce qui est attendu |
| `deadline` | `{date, text, precision}` |
| `confidence` | 0…1 |
| `evidence` | `[{rule, explanation, excerpt}]` |
| `isMissionCandidate` | voir §4 |
| `metadata` | métadonnées techniques (fichier : chemin relatif, catégorie, extension, taille, type de changement) |

Le corps complet des e-mails et le contenu des fichiers ne sont **jamais**
stockés : seulement un résumé et des extraits justificatifs courts (≤ 160 caractères).

## 6. Sécurité et confidentialité

| Exigence | Mise en œuvre |
|----------|---------------|
| Aucun accès sans autorisation | `TrustEngine.require` / `requireFolderAccess` avant chaque collecte ; tests R06 |
| Aucune collecte globale du disque | Bac à sable macOS + dossier choisi uniquement + revérification de chaque sous-dossier + liens non suivis |
| Aucune transmission externe non autorisée | `GuardedHTTPClient` : HTTPS obligatoire, liste blanche (2 hôtes Google), permission vérifiée, redirections HTTP refusées ; tests R10 |
| Secrets protégés | Trousseau macOS ; jamais dans les fichiers ni les journaux |
| Journalisation des accès | `AccessLog` (JSON Lines) : date, source, opération, cible, résultat — jamais de contenu |
| Suppression des données | « Supprimer les données collectées » (événements + états de sources, et optionnellement le journal) |
| Séparation par utilisateur | `GhostProfile` : un répertoire par utilisateur macOS ; jetons du Trousseau préfixés par profil |
| Activité visible | icône de barre de menus selon l'état, statut dans le tableau de bord et la fenêtre |
| Pas de surveillance cachée | aucune capture d'écran, aucun keylogging, aucune observation d'applications ; aucune autorisation système de ce type demandée |

Données sur disque (bac à sable) :
`~/Library/Containers/app.ghost.shell/Data/Library/Application Support/GHOST/profiles/<utilisateur>/`
(`events.json`, `grants.json`, `access-log.jsonl`, `sources/`).

**Limites connues** : les fichiers du profil ne sont pas chiffrés par GHOST
(ils bénéficient de la protection du conteneur du bac à sable et de FileVault
si activé) ; le journal d'accès n'est pas infalsifiable.

## 7. Limites de la mission

GHOST PERCEPTION n'exécute aucune tâche, n'envoie aucun e-mail, ne modifie ni
ne supprime aucun document, ne contrôle aucune application et ne prend aucune
décision ayant des conséquences externes.
