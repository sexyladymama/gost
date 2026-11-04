# Connecter une boîte Gmail de test

GHOST n'inclut **aucun identifiant Google**. Sans configuration, utilisez la
boîte de test simulée (Sources ▸ « Utiliser la boîte de test »).

Pour une vraie boîte Gmail **de test** :

1. Ouvrir la [console Google Cloud](https://console.cloud.google.com/) et créer un projet.
2. *API et services ▸ Bibliothèque* : activer **Gmail API**.
3. *API et services ▸ Écran de consentement OAuth* :
   - type d'utilisateur **Externe**, statut **Test** ;
   - ajouter la portée `https://www.googleapis.com/auth/gmail.readonly` ;
   - ajouter l'adresse de la boîte de test dans **Utilisateurs test**.
4. *API et services ▸ Identifiants ▸ Créer des identifiants ▸ ID client OAuth* :
   - type d'application : **iOS** (ce type convient aussi aux applications macOS
     natives et n'a pas de secret client) ;
   - ID du bundle : `app.ghost.shell`.
5. Copier l'**ID client** (`…apps.googleusercontent.com`).
6. Dans GHOST : *Voir ce que GHOST a détecté… ▸ Sources ▸ Compte Gmail réel*,
   coller l'ID client, puis **Connecter Gmail…**. Une fenêtre Google s'ouvre ;
   se connecter avec la boîte de test et accepter l'accès en lecture seule.

Ce qui se passe ensuite :
- GHOST relève les **nouveaux** e-mails de la boîte de réception (pas les anciens),
  toutes les 60 s, tant que GHOST est ACTIVE ;
- le jeton est stocké dans le Trousseau macOS ;
- **Révoquer l'accès e-mail** révoque le jeton auprès de Google et l'efface.

Vous pouvez aussi retirer l'accès depuis votre compte Google :
<https://myaccount.google.com/permissions>.

> Cette intégration a été testée uniquement contre des réponses HTTP simulées
> reproduisant l'API Gmail. Elle n'a pas été exécutée contre un vrai compte
> Google pendant le développement (aucun identifiant disponible).
