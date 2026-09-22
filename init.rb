require 'redmine'

require_relative 'lib/redmine_issue_export_import/hooks'

# Répertoire réel du plugin, déduit de l'emplacement de ce fichier init.rb.
# Il permet d'installer le plugin dans un dossier portant n'importe quel nom
# (par défaut celui du dépôt : redmine_plugin_import_export_siae-aiacp).
# Sans cette déclaration explicite (voir `directory` ci-dessous), Redmine
# impose que le dossier soit nommé d'après l'identifiant du plugin et refuse
# de démarrer sinon, avec une erreur du type :
#   PluginNotFound: Plugin not found. The directory for plugin
#   redmine_issue_export_import should be .../plugins/redmine_issue_export_import.
# File.expand_path est utilisé volontairement à la place de __dir__ : on
# conserve ainsi le chemin tel qu'il a été chargé par Redmine, ce qui reste
# correct si le dossier du plugin est un lien symbolique ou un point de
# montage (cas fréquent avec Docker).
plugin_directory = File.dirname(File.expand_path(__FILE__))

Redmine::Plugin.register :redmine_issue_export_import do
  name 'Export / Import des demandes avec pièces jointes'
  author 'siae-aiacp'
  description "Exporte le résultat d'une requête de demandes (CSV + pièces jointes classées par numéro de demande) dans un répertoire, et permet de réimporter ce répertoire pour mettre à jour les demandes après vérification des changements."
  version '1.1.0'
  url 'https://github.com/ibibah/redmine_plugin_import_export_siae-aiacp'
  author_url 'https://github.com/ibibah/redmine_plugin_import_export_siae-aiacp'

  # Le dossier d'installation peut porter n'importe quel nom : on déclare ici
  # le répertoire effectif du plugin (celui qui contient ce fichier). Voir le
  # commentaire ci-dessus.
  directory plugin_directory

  requires_redmine version_or_higher: '4.2.0'

  settings default: {
    'csv_separator' => ';'
  }, partial: 'settings/issue_export_import_settings'

  project_module :issue_export_import do
    permission :export_issues_with_attachments,
               { issue_export_import: [:export] },
               read: true

    # Donne accès à l'écran d'import. Le contrôleur vérifie en plus, pour
    # chaque demande individuellement, que l'utilisateur possède bien cette
    # permission sur le PROJET de la demande concernée avant d'appliquer un
    # changement (un export peut contenir des demandes de plusieurs
    # projets). Les administrateurs Redmine ont toujours accès, quel que
    # soit ce réglage.
    permission :import_issues_from_export,
               { issue_export_import: [:new_import, :preview, :apply] },
               require: :member
  end
end

# Le module d'import lit/écrit sur le système de fichiers du serveur à un
# chemin fourni par l'utilisateur. Il est accessible :
#  - à tout administrateur Redmine ;
#  - à tout utilisateur disposant de la permission "import_issues_from_export"
#    sur au moins un projet (typiquement les chefs de projet / managers) —
#    voir IssueExportImportController#authorize_import_access.
# Voir le README pour les implications de sécurité (restriction au
# répertoire racine des exports, notamment).
#
# Le lien vers l'écran d'import est affiché directement à côté du bouton
# "Exporter avec pièces jointes" sur la page de résultats de requête (voir
# app/views/issue_export_import/_export_button.html.erb) ; il n'y a donc
# pas d'entrée dédiée dans le menu de projet, pour éviter la redondance.
Rails.application.config.after_initialize do
  # Entrée dans le menu Administration (visible seulement par les admins)
  if Redmine::MenuManager.map(:admin_menu)
    Redmine::MenuManager.map(:admin_menu).push(
      :issue_export_import,
      { controller: 'issue_export_import', action: 'new_import' },
      caption: :label_issue_export_import_menu,
      html: { class: 'icon icon-import' }
    )
  end
end
