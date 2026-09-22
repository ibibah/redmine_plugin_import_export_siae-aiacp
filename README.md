# redmine_plugin_import_export_siae-aiacp

Plugin Redmine : export d'une requête de demandes (issues) vers une
archive **.zip téléchargée sur le poste client** (CSV + pièces jointes
classées par numéro de demande), et réimport de cette archive **déposée
depuis le poste client** avec écran de vérification des différences avant
application.

Aucun répertoire serveur à configurer : l'export se télécharge comme
n'importe quel fichier, l'import se dépose comme n'importe quel upload.

- **Dépôt / dossier d'installation** : `redmine_plugin_import_export_siae-aiacp`
  (n'importe quel nom de dossier convient, voir « Installation »).
- **Identifiant interne du plugin** : `redmine_issue_export_import` — il
  apparaît dans l'URL de configuration
  (`/settings/plugin/redmine_issue_export_import`) et dans la clé de réglage
  (`plugin_redmine_issue_export_import`). Seul le **nom du dossier**
  d'installation est libre ; cet identifiant doit rester inchangé, sans quoi
  les réglages existants (séparateur CSV) sont perdus.

## Fonctionnement

### 1. Export

Sur la page de résultats d'une requête de demandes (`/issues`), un bouton
**"Exporter avec pièces jointes"** apparaît (sous réserve de la permission
correspondante). Il exécute la requête **actuellement affichée** (mêmes
filtres, mêmes colonnes sélectionnées) et déclenche le téléchargement d'un
fichier `export_20260704_143000.zip` contenant :

```
export_20260704_143000.zip
├── issues.csv                 # une ligne par demande, colonnes = celles sélectionnées dans la requête
├── rapport/
│   └── rapport.html            # rapport HTML unique, autonome, imprimable/PDF, toutes les demandes
├── 101/                       # pièces jointes de la demande #101
│   ├── plan.pdf
│   └── photo.jpg
├── 104/                       # pièces jointes de la demande #104
│   └── devis.xlsx
└── ...
```

- Le CSV contient toujours la colonne `id`, suivie des colonnes
  sélectionnées dans la requête (statut, priorité, assigné à, champs
  personnalisés, etc.). Les en-têtes des champs personnalisés incluent
  leur identifiant technique (ex. `Origine [cf_5]`) afin que le ré-import
  reste fiable même si le libellé du champ change entre-temps.
- Un sous-répertoire n'est créé dans l'archive que pour les demandes ayant
  au moins une pièce jointe.
- **Le rapport HTML (`rapport/rapport.html`)** est généré automatiquement
  à chaque export, en plus du CSV technique — les deux coexistent dans la
  même archive sans interférer (le dossier `rapport/` est distinct des
  répertoires numérotés utilisés pour les pièces jointes, donc jamais pris
  pour une pièce jointe lors d'un ré-import ultérieur). C'est un **fichier
  HTML unique** regroupant toutes les demandes exportées, pensé pour être
  transmis tel quel à une personne externe, imprimé, exporté en PDF (via
  "Imprimer" du navigateur), ou projeté en réunion :
  - **Autonome** (CSS intégré, aucune dépendance internet) : s'ouvre
    directement en double-cliquant dessus, sans serveur ni connexion à
    Redmine.
  - **Un sommaire en haut de page**, avec liens d'ancrage vers chaque
    demande ; si la requête exportée utilise un regroupement ("Group
    results by" dans Redmine), le sommaire reprend ce même groupement
    (sous-titres par groupe). Une barre supérieure fixe (masquée à
    l'impression) permet de revenir au sommaire ou de lancer l'impression
    à tout moment.
  - **Imprimable / export PDF** : chaque demande démarre sur une nouvelle
    page à l'impression, les éléments d'interface (barre de navigation,
    liens "retour au sommaire") sont automatiquement masqués, pour un
    rendu propre sur papier ou en PDF.
  - **Couleurs reprises de Redmine** (bleu d'en-tête `#628db6` et bleu
    foncé `#3e5b76` du thème par défaut), pour rester visuellement
    cohérent avec l'interface, sans être une reproduction pixel pour pixel
    du thème (les feuilles de style de Redmine ne sont pas conçues pour
    fonctionner hors serveur/hors connexion).
  - **Demande parente, sous-tâches et demandes liées** sont affichées pour
    chaque demande, avec le type de relation (ex. "Précède", "Bloque").
    Si la demande référencée fait aussi partie de l'export, un lien
    d'ancrage y mène directement (`#issue-<id>`) ; sinon, elle est
    affichée en texte simple suivi de "(hors export)", puisqu'aucun lien
    utilisable ne peut être généré vers un document hors ligne.
  - La description et les commentaires sont rendus avec le moteur de mise
    en forme de Redmine (Textile/Markdown selon votre configuration),
    donnant un rendu identique à celui de l'interface — pas de texte brut.
  - **L'historique complet** de la demande (changements de champs et
    commentaires, avec auteur et date) est inclus dans l'ordre
    chronologique.
  - **Les notes marquées "privées" dans Redmine sont systématiquement
    exclues** de ce rapport, puisqu'il est destiné à un usage externe.
  - Les pièces jointes sont listées avec des liens cliquables vers le
    répertoire correspondant (`../101/fichier.pdf`).
  - Attention : le rapport reflète ce que **l'utilisateur qui exporte**
    peut voir au moment de l'export (y compris la visibilité des champs
    personnalisés) — pensez à vérifier qu'aucune information sensible non
    destinée à l'externe ne s'y trouve avant de transmettre l'archive.
- **Où atterrit le fichier ?** C'est le navigateur du poste client qui
  gère l'enregistrement (dossier "Téléchargements" par défaut, ou boîte de
  dialogue "Enregistrer sous" si l'utilisateur a activé cette option dans
  les réglages de son navigateur — un site web ne peut pas forcer
  l'affichage de cette boîte de dialogue, c'est un choix qui appartient au
  navigateur).

### 2. Import (retour de la modification)

Accessible :

- via **Administration > Import demandes (retour d'export)** pour les
  administrateurs ;
- via le lien **« Import demandes (retour d'export) »** affiché juste à côté
  du bouton d'export, sur la page de résultats de requête des demandes
  (`/issues`), pour les utilisateurs disposant de la permission **« Importer
  les demandes depuis un export »** sur au moins un projet (typiquement le
  rôle Manager). Il n'y a volontairement **pas d'entrée dans le menu du
  projet** : le lien est placé au même endroit que l'export, pour éviter la
  redondance.

Étapes :

1. **Sélectionner le fichier .zip** via le bouton "Choisir un fichier"
   (ouvre la boîte de dialogue native de sélection de fichier du poste
   client). Il peut s'agir du zip exporté tel quel, ou d'une version
   modifiée : l'utilisateur peut le décompresser sur son poste, corriger
   des valeurs dans `issues.csv`, ajouter des fichiers dans les
   sous-répertoires par numéro de demande, puis recompresser le tout en
   `.zip` avant de le déposer ici.
2. Le zip est envoyé au serveur, décompressé dans un répertoire temporaire
   propre à cette session d'import (identifiant aléatoire), puis analysé.
3. **Écran de vérification** : pour chaque demande concernée, le plugin
   affiche uniquement les champs dont la valeur diffère de la base actuelle
   (ancienne valeur / nouvelle valeur), ainsi que les nouvelles pièces
   jointes détectées et un éventuel commentaire à ajouter (voir ci-dessous).
   Chaque ligne est cochée par défaut ; il suffit de décocher ce qui ne
   doit pas être appliqué.
4. Validation : les changements cochés sont appliqués un par un
   (transaction par demande), un journal est ajouté sur chaque demande
   modifiée pour tracer l'origine de l'import, un compte-rendu final liste
   les demandes mises à jour et les éventuelles erreurs, puis le
   répertoire temporaire est supprimé du serveur.

- L'accès à l'écran est ouvert dès que l'utilisateur a la permission
  d'import sur **au moins un** projet.
- **Mais l'application des changements reste filtrée demande par
  demande** : si l'archive contient des demandes de plusieurs projets, un
  manager ne verra/n'appliquera que les changements sur les demandes des
  projets où il a la permission ; les autres sont ignorées avec un message
  explicite (« X demande(s) ignorée(s) car... »). Un administrateur voit et
  traite toutes les demandes.
- Les répertoires temporaires d'import oubliés (session non finalisée)
  sont automatiquement purgés au bout de 2 heures.

## Installation

```bash
cd /path/to/redmine/plugins
git clone https://github.com/ibibah/redmine_plugin_import_export_siae-aiacp.git \
          redmine_plugin_import_export_siae-aiacp
# ou copier simplement le dossier redmine_plugin_import_export_siae-aiacp ici

cd /path/to/redmine
bundle install   # installe la dépendance rubyzip déclarée dans le Gemfile du plugin
RAILS_ENV=production bin/rails redmine:plugins:migrate   # aucune migration nécessaire, mais recommandé par habitude
sudo service redmine restart   # ou passenger-config restart-app, etc.
```

**Le dossier d'installation peut porter n'importe quel nom** — par convention
celui du dépôt, `redmine_plugin_import_export_siae-aiacp` (dans l'image
Docker officielle : `/usr/src/redmine/plugins/redmine_plugin_import_export_siae-aiacp`).
`init.rb` déclare en effet explicitement son propre répertoire
(`directory ...`, calculé depuis l'emplacement du fichier `init.rb`) : sans
cela, Redmine exige un dossier nommé d'après l'identifiant du plugin et
refuse de démarrer avec :

```
PluginNotFound: Plugin not found. The directory for plugin
redmine_issue_export_import should be .../plugins/redmine_issue_export_import.
```

⚠️ **Une seule copie du plugin dans `plugins/`** : si un ancien dossier
subsiste (dossier renommé au lieu d'être supprimé, lien symbolique, double
point de montage Docker…), le plugin est chargé deux fois et `bundle install`
signale les gems des Gemfiles en double (`Your Gemfile lists the gem rubyzip
(~> 2.3.0) more than once`). Supprimez l'ancien dossier, puis relancez
`bundle install` et Redmine.

Le plugin ajoute une dépendance : la gem **rubyzip** (`~> 2.3.0`, pour des
raisons de sécurité — les versions antérieures sont déconseillées), déclarée
dans `Gemfile` à la racine du plugin. Redmine charge automatiquement les
`Gemfile` des plugins lors du `bundle install` à la racine de l'application.
Selon la source de gems disponible dans votre environnement, la contrainte
`~> 2.3.0` peut échouer à résoudre une version précise ; dans ce cas, fixez
une version exacte disponible (ex. `gem 'rubyzip', '2.3.0', require: 'zip'`).

Ensuite, dans **Administration > Plugins > Export / Import des demandes
avec pièces jointes > Configurer**, seul le **séparateur CSV** (`;` par
défaut, adapté à Excel FR) reste à régler.

Puis, dans **Administration > Rôles et permissions** (module *Export /
Import des demandes avec pièces jointes*), cocher pour les rôles concernés :

- **"Exporter les demandes avec pièces jointes"** : pour les rôles pouvant
  utiliser le bouton d'export depuis les résultats de requête.
- **"Importer les demandes depuis un export"** : pour les rôles (ex.
  Manager) pouvant accéder à l'écran d'import et appliquer des changements
  sur les demandes des projets où ils ont ce rôle. Cette permission est de
  type "membre du projet" : elle doit être accordée projet par projet (via
  l'affectation du rôle aux membres), pas globalement.

## Points d'attention / limites connues

- **Ajouter un commentaire à l'import** : le CSV exporté contient toujours
  une colonne supplémentaire `Commentaire à ajouter [import_note]`, vide
  par défaut. Si vous y écrivez du texte avant de réimporter, ce texte
  devient le commentaire ajouté à l'historique de la demande (combiné, le
  cas échéant, avec les changements de champs appliqués dans le même
  import — un seul et même journal, comme dans l'interface Redmine). Si
  la colonne est vide, le message système par défaut ("Import automatique
  depuis un fichier d'export") est utilisé à la place. Ce commentaire
  apparaît dans une section à part sur l'écran de vérification, avec sa
  propre case à cocher. **Limite à connaître** : un commentaire n'a pas
  d'état "déjà appliqué" détectable (contrairement aux champs, comparés à
  la valeur actuelle) ; si vous réimportez deux fois le même fichier sans
  vider cette colonne, le commentaire sera proposé deux fois — il suffit
  de décocher la case la seconde fois.
- **Lignes sans identifiant valide** : une ligne du CSV dont la colonne
  `id` est vide, ou qui référence une demande inexistante, est ignorée
  (ce plugin ne permet pas de créer de nouvelles demandes par import) —
  mais ce n'est plus silencieux : l'écran de vérification affiche un
  avertissement avec le nombre de lignes concernées.
- **Séparateur CSV détecté automatiquement à l'import** : si vous ouvrez
  le CSV exporté dans Excel/LibreOffice puis le ré-enregistrez, le
  tableur peut changer le séparateur (virgule au lieu du point-virgule
  configuré, selon les paramètres régionaux). Le plugin détecte ce cas à
  la lecture (en vérifiant qu'une colonne "id" est bien reconnaissable) et
  bascule automatiquement sur le bon séparateur, plutôt que d'ignorer
  toutes les lignes silencieusement.
- **Champs pris en charge en import** : tracker, statut, priorité, sujet,
  description, assigné à, catégorie, version cible, dates de début/échéance,
  avancement (%), heures estimées, et tous les champs personnalisés. Le
  champ *auteur* et les dates de création/mise à jour sont exportés à
  titre informatif : ils ne sont **jamais comparés ni réimportés**, même
  si leur valeur dans le fichier diffère de la base (leur format de date
  est presque toujours réécrit par un tableur, ce qui les ferait sinon
  apparaître à tort comme modifiés).
- **Correspondance par nom** : les champs de type liste (statut, priorité,
  catégorie, version, assigné à) sont réimportés en recherchant l'objet
  par son **nom exact** (ou login pour un utilisateur). Renommer un statut
  entre l'export et l'import cassera la correspondance pour ce champ.
- **Pièces jointes** : seuls les fichiers *nouveaux* (nom absent des
  pièces jointes déjà attachées à la demande) sont proposés à l'ajout ;
  le plugin ne supprime ni ne remplace de pièce jointe existante.
- **Taille des exports** : l'archive est construite en mémoire côté serveur
  avant l'envoi (aucun fichier ne reste sur le disque du serveur après
  l'export). Pour des exports volumineux (beaucoup de grosses pièces
  jointes), cela consomme davantage de mémoire côté serveur ; pensez à
  filtrer la requête si nécessaire. La taille maximale d'upload pour
  l'import dépend des réglages standards de votre serveur web (ex.
  `client_max_body_size` sous nginx) et de Rails, pas du plugin lui-même.
- **Rendu du rapport HTML** : utilise le helper Redmine `textilizable`
  (le même que celui utilisé pour afficher une demande dans l'interface),
  ce qui peut résoudre des liens wiki, des références `#123` vers d'autres
  demandes, etc. — ces liens pointeront vers votre instance Redmine en
  ligne (normal pour un rapport statique) ; ils ne fonctionneront donc que
  si le destinataire externe a accès à cette instance.
  Les pièces jointes sont traitées différemment : les liens `attachment:nom`
  et les images collées au clavier (`![](nom.png)`) sont bien résolus
  (la liste des pièces jointes de la demande est explicitement transmise
  à `textilizable`, comme le fait Redmine lui-même), puis les liens
  générés — qui pointent par défaut vers le serveur Redmine, sous l'une
  des 3 formes possibles (`/attachments/<id>`,
  `/attachments/download/<id>/...` ou `/attachments/thumbnail/<id>...`) —
  sont automatiquement réécrits vers le fichier local correspondant dans
  l'archive (`../<id>/<nom_fichier>`), pour que le rapport reste
  consultable entièrement hors ligne. L'attribut `loading="lazy"` que
  Redmine ajoute sur les images est aussi retiré, car le chargement
  différé peut empêcher l'affichage d'une image dans un fichier ouvert
  localement ou lors d'un export/impression en PDF. Seules les pièces
  jointes réellement présentes dans l'export (donc listées dans le
  dossier numéroté de la demande) sont réécrites de la sorte ; une
  référence à une pièce jointe supprimée entre-temps reste un lien mort.
- **Route d'export** : le chemin utilisé est `/issue_export_import/export`
  (et non `/issues/...`) afin d'éviter toute collision avec la route
  native de Redmine `/issues/:id` (résolution de demande par identifiant),
  chargée avant les routes des plugins. Ne renommez pas ce chemin vers
  quelque chose commençant par `issues/` sans vérifier qu'il ne recoupe
  aucune route native.
- **Avertissements `Your Gemfile lists the gem … more than once`** : bénins
  tant qu'ils sont suivis de `The Gemfile's dependencies are satisfied`. Ils
  proviennent de la racine de Redmine, qui évalue son `Gemfile` **et** ceux
  des plugins (`Dir.glob("plugins/*/{Gemfile,PluginGemfile}")`), et le plus
  souvent de la présence de **deux copies du plugin** dans `plugins/` (ancien
  dossier + nouveau, lien symbolique, double montage Docker…). Vérifiez qu'il
  n'en reste qu'une seule.
- **Compatibilité de version** : ciblé et vérifié pour **Redmine 5.1.x /
  Ruby 3.2 / Rails 6.1** (ex. Redmine 5.1.17, image Docker officielle
  `redmine:5.1`). Le hook `view_issues_index_bottom`
  utilisé pour le bouton d'export a été vérifié directement sur le code
  source de cette branche (`app/views/issues/index.html.erb`, signature
  `:issues, :project, :query` inchangée). Les autres API utilisées
  (`IssueQuery#build_from_params`, `Query#columns`, `Attachment.create`,
  `custom_field_value` / `custom_field_values=`, `Redmine::MenuManager`,
  `IssuesHelper#details_to_strings`, `CustomFieldsHelper#format_value`,
  `Journal#visible_details`) sont stables depuis Redmine 4.2 (vérifiées sur
  les branches 4.2, 5.0 et 5.1). L'API `rubyzip` utilisée
  (`Zip::File.open`, `zipfile.add`, `entry.extract`) est stable depuis
  plusieurs versions majeures de la gem. **Testez malgré tout sur un
  environnement de recette avant mise en production.**
- Aucune donnée n'est stockée en base par le plugin (pas de nouvelle
  table) : le seul état conservé entre les deux requêtes HTTP de l'import
  (aperçu → application) est le répertoire temporaire extrait du zip,
  identifié par un token aléatoire et supprimé après application (ou après
  2 heures d'inactivité).

## Sécurité

- L'accès à l'écran d'import est ouvert aux administrateurs et aux
  utilisateurs disposant de la permission "Importer les demandes depuis un
  export" sur au moins un projet.
- **Filtrage par demande** : quel que soit le point d'entrée (menu admin ou
  menu projet), chaque changement n'est appliqué que si l'utilisateur a la
  permission d'import sur le projet de la demande concernée. Un manager ne
  peut donc jamais modifier, via ce mécanisme, une demande d'un projet où
  il n'a pas cette permission, même si elle figure dans l'archive importée.
- **Protection "zip slip"** : à l'extraction, toute entrée d'archive dont
  le chemin sortirait du répertoire temporaire de travail (ex. noms de
  fichiers contenant `../`) est rejetée.
- Le token d'identification du répertoire temporaire d'import est généré
  côté serveur (aléatoire, non prévisible) ; aucun chemin fourni par
  l'utilisateur n'est utilisé tel quel sur le système de fichiers.

## Journal des modifications

### 1.1.0 — 2026-09

- **Correction du bouton « Exporter avec pièces jointes »** : l'export
  échouait avec
  `Échec de l'export : undefined method 'format_value' for #<ActionView::Base…>`
  dès qu'une demande exportée avait un changement de **champ personnalisé**
  dans son historique. L'historique du rapport HTML est rendu par
  `IssuesHelper#details_to_strings`, qui appelle `format_value` (défini dans
  `CustomFieldsHelper`) : c'était le seul helper Redmine utilisé par le
  rapport qui n'était pas déclaré dans le contrôleur du plugin. Ajout de
  `helper :custom_fields` (exactement comme `IssuesController`).
- **Nom du dossier d'installation libre** : `init.rb` déclare désormais
  explicitement son répertoire (`directory`), ce qui permet d'installer le
  plugin dans un dossier nommé `redmine_plugin_import_export_siae-aiacp` (ou
  tout autre nom) sans que Redmine refuse de démarrer
  (`PluginNotFound: The directory for plugin … should be …`).
- **Confidentialité de l'historique** : le rapport utilise désormais
  `Journal#visible_details` au lieu de `Journal#details`, comme l'onglet
  « Historique » de Redmine. Les changements de champs personnalisés que
  l'utilisateur qui exporte n'est pas autorisé à voir ne figurent plus dans
  le rapport — utile puisque ce rapport peut être transmis à des personnes
  externes (au même titre que les notes privées, déjà exclues).
- Divers : URL du dépôt renseignée sur la page **Administration > Plugins**
  (au lieu du `exemple.local` d'origine).

### 1.0.1 — 2026-09

- **Redmine ne démarrait plus** (Puma : `Exiting`) après l'ajout du rapport
  HTML : trois lignes du contrôleur contenaient un antislash parasite
  (`\"…\"` au lieu de `"…"`, dans `column_caption`, `sort_criteria_to_s` et
  `filters_to_s`), ce qui provoquait à l'eager load :
  `syntax error, unexpected backslash, expecting ')' (SyntaxError)`.
