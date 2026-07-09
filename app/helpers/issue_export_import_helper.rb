module IssueExportImportHelper
  # Redmine (textilizable) résout déjà correctement les expressions
  # "attachment:fichier" (Textile) et "![](fichier)" / pièces jointes
  # collées (Markdown) en liens/images vers l'URL de téléchargement ou de
  # vignette de la pièce jointe (ex. "/attachments/download/12/fichier.png"
  # ou "/attachments/thumbnail/12"). Ces URL pointent vers le serveur
  # Redmine et ne fonctionnent pas dans un rapport HTML ouvert hors
  # connexion (file://) : on les réécrit ici vers le dossier local de la
  # demande dans l'archive exportée (ex. "../101/fichier.png"), qui existe
  # réellement à côté du rapport.
  def localize_attachment_links(html, issue)
    return html if html.blank?

    attachments_by_id = issue.attachments.index_by(&:id)

    html.gsub(%r{(href|src)="((?:https?://[^/"']+)?/attachments/(?:download|thumbnail)/(\d+)(?:/[^"']*)?)"}) do
      attr = Regexp.last_match(1)
      original = Regexp.last_match(2)
      attachment_id = Regexp.last_match(3).to_i
      attachment = attachments_by_id[attachment_id]

      if attachment
        %(#{attr}="../#{issue.id}/#{attachment.filename}")
      else
        # Pièce jointe introuvable (ex. supprimée depuis) : on laisse le
        # lien d'origine plutôt que de le casser silencieusement.
        %(#{attr}="#{original}")
      end
    end.html_safe
  end
end
