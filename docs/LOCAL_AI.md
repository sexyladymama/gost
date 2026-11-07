# L'IA propre de GHOST

GHOST embarque sa propre IA : un modèle de langage **ouvert** exécuté **sur ce Mac**, sans clé, sans compte, sans réseau pour raisonner.

## Ce que c'est (et ce que ce n'est pas)

- Ce n'est **pas** une IA créée de zéro : entraîner un modèle comparable demande des milliers de cartes graphiques et des mois. GHOST embarque un modèle déjà entraîné, libre de droits, et construit autour de lui tout ce qui fait un agent (mémoire, outils, confiance, vérification).
- Modèle : **Qwen 2.5 7B Instruct** (Alibaba Cloud, licence Apache-2.0), quantifié Q4_K_M, format GGUF, ≈ 4,7 Go, 7 milliards de paramètres (≈ 2 à 3 fois plus qu'Apple Intelligence sur appareil).
- Moteur d'exécution : **llama.cpp** (version b12171, binaire officiel de ggml-org) avec accélération Metal sur puce Apple.

## Fournisseur et passerelle

`LocalOpenModelProvider` (package `Packages/GhostLocalLLM`) est un fournisseur de la passerelle commune, préféré avant Apple Intelligence et avant tout modèle externe. Il sert Brain, Mind (mails, documents, logos) et Core.
Pour les décisions d'agent, la sortie est contrainte par une **grammaire GBNF** : le modèle ne peut produire que du JSON conforme au protocole de GHOST CORE, avec un outil parmi ceux réellement proposés. La validation stricte de Core reste en aval.

## Sécurité de la chaîne

| Élément | Protection |
|---|---|
| Runtime | binaire épinglé par **version et somme de contrôle SHA-256** dans `Package.swift` (b52872ea…), vérifiée à la résolution ; signé avec le certificat de l'app, bac à sable conservé |
| Modèle | téléchargé depuis `huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF` à une **révision fixe** (`bb5d59e0…`), taille et **SHA-256** de chaque fichier épinglés dans le code ; un fichier inattendu est supprimé et jamais chargé |
| Téléchargement | déclenché par l'utilisateur ; reprenable ; annulable ; le seul accès réseau nécessaire (aucune donnée personnelle envoyée) |
| Exécution | aucune conversation conservée entre deux demandes ; la mémoire de ~5 Go se libère à la demande |

## Utilisation

Objectifs ▸ « IA de GHOST » : **Télécharger** (4,7 Go), puis tout le reste l'utilise automatiquement. Supprimer libère le disque.
Prérequis : puce Apple Silicon, ≈ 8 Go de mémoire libre pendant la génération, macOS 14 ou plus.

## Limites

Un modèle de 7 milliards de paramètres reste nettement moins capable que les grands modèles externes : plan plus approximatif, erreurs possibles, réponses de plusieurs dizaines de secondes. La qualité est mesurée dans `docs/CORE.md`.
