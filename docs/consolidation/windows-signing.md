# Identité de signature de l'exemple Windows

La consolidation retire le conteneur de signature suivi et ses propriétés de
certificat dans le projet Windows. La signature est désactivée par défaut.
Cette livraison ne qualifie pas la compilation ni l'exécution Windows.

Pour un empaquetage local ultérieur, créer une identité de développement jetable
dans le magasin de certificats du poste. Conserver les éventuels fichiers et
paramètres MSBuild dans une configuration privée hors du dépôt. Ne pas placer
un mot de passe dans la ligne de commande, les logs ou une configuration suivie.

L'utilisation historique de l'identité supprimée reste **inconnue**. Sa
suppression ne prouve aucune révocation ni rotation. Les deux documents dans
`.release/windows-signing-identity-*.json` conservent l'évaluation `unknown` et
la remédiation `pending`, liées aux octets exacts de l'attestation par SHA-256.
Le programme demeure gelé. Une future levée du gel exige une évaluation factuelle
et une preuve liée de non-utilisation externe, de rotation ou de révocation.

Vérifications locales :

```sh
yarn verify:secrets
yarn test:secrets
yarn test:release
```

Le scanner contrôle les fichiers suivis et ne journalise que leurs chemins et
des codes fixes. Pour contrôler un paquet extrait, passer `--root` avec le
dossier extrait et `--inventory` avec un tableau JSON non vide de chemins
relatifs provenant de son inventaire. Il refuse les chemins sortants, les liens,
les fichiers absents, les clés privées PEM et les identités de signature.
Les propriétés MSBuild sont analysées comme du XML ; les DTD sont interdites.
