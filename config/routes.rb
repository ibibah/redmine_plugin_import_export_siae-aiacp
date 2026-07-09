# Export : déclenché depuis la page de résultats de requête des demandes
# (méthode GET pour pouvoir reprendre les mêmes paramètres de requête/filtres
# que ceux affichés à l'écran, comme le fait l'export CSV natif de Redmine).
#
# IMPORTANT : ce chemin ne doit surtout pas commencer par "issues/" — la
# route native de Redmine "resources :issues" (donc "/issues/:id" vers
# IssuesController#show, sans contrainte numérique sur :id) est chargée
# AVANT les routes des plugins, et intercepterait la requête en prenant
# "export_with_attachments" pour un identifiant de demande (d'où un 404
# via IssuesController#show au lieu de notre action d'export). On utilise
# donc un chemin sous le nom du contrôleur du plugin, qui ne peut entrer
# en collision avec aucune route native.
get 'issue_export_import/export', to: 'issue_export_import#export',
    as: 'export_issues_with_attachments'

# Import : accessible aux administrateurs et aux utilisateurs disposant de
# la permission "import_issues_from_export" sur au moins un projet
get  'issue_export_import/new',      to: 'issue_export_import#new_import', as: 'new_issue_export_import'
post 'issue_export_import/preview',  to: 'issue_export_import#preview',    as: 'preview_issue_export_import'
post 'issue_export_import/apply',    to: 'issue_export_import#apply',      as: 'apply_issue_export_import'
