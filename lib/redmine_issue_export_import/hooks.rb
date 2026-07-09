module RedmineIssueExportImport
  class Hooks < Redmine::Hook::ViewListener
    # Ce hook est appelé par Redmine en bas de la vue app/views/issues/index.html.erb
    # (page de résultats de requête des demandes), juste après les liens
    # "CSV / PDF / Atom" natifs. Si votre version de Redmine ne déclenche pas
    # ce hook précis, ajoutez l'appel équivalent dans votre thème/vue,
    # ou basculez sur :view_issues_index_sidebar_query_form_bottom.
    render_on :view_issues_index_bottom, partial: 'issue_export_import/export_button'
  end
end
