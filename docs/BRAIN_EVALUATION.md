# Évaluation du cerveau — scénarios de référence

Généré par `BrainEvaluationTests` (modèle **non utilisé** : règles seules, aucune API). Taux calculés sur 26 scénarios réellement exécutés (chaque scénario est exécuté deux fois pour la stabilité).

| Mesure | Résultat |
|---|---|
| Précision de détection des missions | 100 % (16/16) |
| Rappel (missions manquées : 0) | 100 % (16/16) |
| Faux positifs (missions créées à tort) | 0 |
| Décision finale dans l'ensemble attendu | 100 % (26/26) |
| Échéance correcte | 100 % (7/7) |
| Priorité exacte | 100 % (9/9) |
| Priorité à un niveau près | 100 % (9/9) |
| État final de la mission | 100 % (9/9) |
| Nombre de missions (dédoublonnage) | 100 % (6/6) |
| Qualité des plans (contrôles automatiques) | 100 % (16/16) |
| Violations de permissions (écriture/envoi non soumis à validation) | 0 |
| Missions marquées exécutables | 0 |
| Stabilité entre deux analyses | 100 % (26/26) |

| Scénario | Décisions | Mission finale | Verdict |
|---|---|---|---|
| 01 Excel demain, source connue | CREATE_MISSION | PROPOSED · HIGH | ✅ |
| 02 Excel demain, source absente | CREATE_MISSION | BLOCKED · HIGH | ✅ |
| 03 Rapport Q3 (anglais), vendredi | CREATE_MISSION | BLOCKED · NORMAL | ✅ |
| 04 Relance contrat avant vendredi | CREATE_MISSION | BLOCKED · HIGH | ✅ |
| 05 Disponibilité réunion jeudi 14 h | CREATE_MISSION | BLOCKED · NORMAL | ✅ |
| 06 Newsletter | IGNORE | — | ✅ |
| 07 Information horaire (en copie) | REMEMBER | — | ✅ |
| 08 Remerciement | IGNORE | — | ✅ |
| 09 Demande vague | MONITOR | — | ✅ |
| 10 Souhait vague de rencontre | IGNORE | — | ✅ |
| 11 Demande adressée à quelqu'un d'autre (en copie) | MONITOR | — | ✅ |
| 12 Message automatique | IGNORE | — | ✅ |
| 13 Annulation par le demandeur | CREATE_MISSION → UPDATE_MISSION | CANCELLED · HIGH | ✅ |
| 14 Échéance modifiée | CREATE_MISSION → UPDATE_MISSION | BLOCKED · NORMAL | ✅ |
| 15 Relance sans doublon | CREATE_MISSION → UPDATE_MISSION | BLOCKED · HIGH | ✅ |
| 16 Échéances contradictoires | CREATE_MISSION → UPDATE_MISSION | NEEDS_CLARIFICATION · HIGH | ✅ |
| 17 Accusé de réception | CREATE_MISSION → COMPLETE_MISSION | COMPLETED · HIGH | ✅ |
| 18 Relecture de contrat, document connu | CREATE_MISSION | PROPOSED · HIGH | ✅ |
| 19 Dossier non autorisé | CREATE_MISSION | BLOCKED · NORMAL | ✅ |
| 20 Urgent, devis client | CREATE_MISSION | BLOCKED · HIGH | ✅ |
| 21 Contrat cadre fin de mois, interlocuteur inconnu | CREATE_MISSION | BLOCKED · NORMAL | ✅ |
| 22 Relecture ce soir | CREATE_MISSION | BLOCKED · HIGH | ✅ |
| 23 Conversation courte | IGNORE | — | ✅ |
| 24 Fichier sans lien | IGNORE | — | ✅ |
| 25 Dépendance résolue par un fichier | CREATE_MISSION → UPDATE_MISSION | PROPOSED · HIGH | ✅ |
| 26 Obligation sans demande | MONITOR | — | ✅ |