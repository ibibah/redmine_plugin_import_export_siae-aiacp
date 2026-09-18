require 'csv'
require 'fileutils'
require 'tmpdir'
require 'tempfile'
require 'securerandom'
require 'zip' # gem rubyzip, voir le Gemfile du plugin

class IssueExportImportController < ApplicationController
  # IssuesHelper#details_to_strings (utilisé dans report_issue.html.erb
  # pour afficher l'historique des champs modifiés) n'est pas inclus par
  # défaut dans le contexte de rendu de ce contrôleur de plugin ; on le
  # déclare explicitement. ApplicationHelper (textilizable, format_time,
  # etc.) est disponible par héritage normal de ApplicationController.
  helper :issues
  helper_method :localize_attachment_links, :issue_ref_link,
                :column_caption, :column_display_value,
                :sort_criteria_to_s, :filters_to_s

  before_action :find_optional_project, only: [:export]
  before_action :authorize_export, only: [:export]

  # L'import est accessible aux administrateurs et aux utilisateurs disposant
  # de la permission "import_issues_from_export" sur au moins un projet (ex.
  # managers). Le filtrage fin par demande (un manager ne peut modifier que
  # les demandes de SES projets) est fait séparément, voir issue_import_allowed?.
  before_action :authorize_import_access, only: [:new_import, :preview, :apply]

  # Colonnes "cœur" toujours proposées (en plus des colonnes personnalisées),
  # dans l'ordre où elles apparaissent si sélectionnées dans la requête.
  # NOTE : "created_on" et "updated_on" sont volontairement absentes d'ici.
  # Si la requête les inclut, elles sont bien exportées dans le CSV à
  # titre informatif (via csv_header/csv_value, indépendants de cette
  # liste), mais ne doivent JAMAIS être comparées ni proposées comme
  # changement à l'import : leur format de date est quasi systématiquement
  # réécrit par un tableur (Excel/LibreOffice), ce qui les faisait
  # apparaître à tort comme modifiées, et elles ne sont de toute façon pas
  # éditables (apply_field_change n'a pas de cas pour ces champs).
  CORE_COLUMNS = %w[tracker status priority subject description author
                     assigned_to category fixed_version start_date due_date
                     done_ratio estimated_hours].freeze

  # Colonnes exportées à titre purement informatif : jamais comparées ni
  # proposées comme changement à l'import (apply_field_change ne sait pas
  # les appliquer, et cela n'aurait pas de sens de le faire pour l'auteur
  # ou les dates de création/mise à jour).
  READONLY_COLUMNS = %w[author created_on updated_on].freeze

  # Suffixe technique (indépendant de la langue) identifiant la colonne CSV
  # dédiée à l'ajout d'un commentaire lors du ré-import. Contrairement aux
  # autres colonnes, elle n'est jamais comparée à une valeur existante :
  # tout texte présent devient le commentaire du journal appliqué à
  # l'import (voir compute_diffs / apply).
  IMPORT_NOTE_SUFFIX = '[import_note]'.freeze

  # Répertoire de travail temporaire, côté serveur, pour les fichiers zip
  # importés le temps de l'aperçu puis de l'application (entre les 2 requêtes
  # HTTP). Un identifiant aléatoire (token) protège contre les collisions et
  # les accès croisés entre utilisateurs ; les dossiers oubliés sont purgés
  # automatiquement (voir cleanup_stale_import_dirs).
  IMPORT_TMP_ROOT = Rails.root.join('tmp', 'issue_export_import').freeze
  IMPORT_TOKEN_MAX_AGE = 2.hours

  # ---------------------------------------------------------------------
  # EXPORT : génère un .zip (issues.csv + pièces jointes) et le fait
  # télécharger par le navigateur du poste client (boîte de dialogue
  # d'enregistrement gérée par le navigateur lui-même).
  # ---------------------------------------------------------------------
  def export
    retrieve_query

    unless @query.valid?
      flash[:error] = l(:error_query_invalid, errors: @query.errors.full_messages.join(', '))
      redirect_to_referer_or issues_path(project_id: @project)
      return
    end

    # Respecte le tri défini dans la requête (sort_criteria) — IssueQuery#issues
    # applique déjà group_by_sort_order + sort_clause + id DESC par défaut.
    # On ne force plus id ASC pour que le sommaire du rapport reflète bien
    # l'ordre affiché à l'écran au moment de l'export.
    issues = @query.issues
    export_columns = build_export_columns(@query)

    zip_data =
      begin
        build_export_zip(issues, export_columns, @query)
      rescue StandardError => e
        Rails.logger.error("[redmine_issue_export_import] export error: #{e.message}\n#{e.backtrace.join("\n")}")
        flash[:error] = l(:error_export_failed, message: e.message)
        nil
      end

    if zip_data.nil?
      redirect_to_referer_or issues_path(project_id: @project)
      return
    end

    send_data zip_data,
              filename: "export_#{Time.current.strftime('%Y%m%d_%H%M%S')}.zip",
              type: 'application/zip',
              disposition: 'attachment'
  end

  # ---------------------------------------------------------------------
  # IMPORT - étape 1 : formulaire de sélection du fichier .zip (poste client)
  # ---------------------------------------------------------------------
  def new_import
  end

  # ---------------------------------------------------------------------
  # IMPORT - étape 2 : dépôt du zip, extraction côté serveur (répertoire
  # temporaire), écran de vérification des différences.
  # ---------------------------------------------------------------------
  def preview
    uploaded = params[:export_zip]

    if uploaded.blank?
      flash[:error] = l(:error_no_zip_uploaded)
      redirect_to new_issue_export_import_path
      return
    end

    cleanup_stale_import_dirs

    token = SecureRandom.hex(16)
    extract_dir = import_tmp_dir(token)

    begin
      FileUtils.mkdir_p(extract_dir)
      extract_zip(uploaded.path, extract_dir)
    rescue StandardError => e
      FileUtils.rm_rf(extract_dir)
      flash[:error] = l(:error_zip_invalid, message: e.message)
      redirect_to new_issue_export_import_path
      return
    end

    csv_file = File.join(extract_dir, 'issues.csv')
    unless File.exist?(csv_file)
      FileUtils.rm_rf(extract_dir)
      flash[:error] = l(:error_csv_not_found)
      redirect_to new_issue_export_import_path
      return
    end

    @import_token = token
    result = compute_diffs(extract_dir, csv_file)
    all_diffs = result[:diffs]
    @skipped_rows_count = result[:skipped_count]
    @diffs = all_diffs.select { |d| issue_import_allowed?(Issue.find(d[:id])) }
    @forbidden_count = all_diffs.size - @diffs.size
  end

  # ---------------------------------------------------------------------
  # IMPORT - étape 3 : application des modifications sélectionnées, puis
  # nettoyage du répertoire temporaire.
  # ---------------------------------------------------------------------
  def apply
    token = params[:import_token].to_s
    extract_dir = import_tmp_dir(token)

    unless token.present? && extract_dir && Dir.exist?(extract_dir)
      flash[:error] = l(:error_import_session_expired)
      redirect_to new_issue_export_import_path
      return
    end

    csv_file = File.join(extract_dir, 'issues.csv')
    diffs = compute_diffs(extract_dir, csv_file)[:diffs]

    selected_fields = params[:apply_field] || {}           # { "123" => { "status" => "1", ... } }
    selected_attachments = params[:apply_attachment] || {} # { "123" => { "fichier.pdf" => "1" } }
    selected_notes = params[:apply_note] || {}             # { "123" => "1" }

    @results = []

    diffs.each do |diff|
      issue = Issue.find_by(id: diff[:id])
      next if issue.nil?

      unless issue_import_allowed?(issue)
        @results << { id: issue.id, applied_fields: [], applied_attachments: [], note_applied: false,
                       errors: [l(:error_issue_import_forbidden)] }
        next
      end

      changes_to_apply = diff[:changes].select do |c|
        selected_fields.dig(diff[:id].to_s, c[:field]) == '1'
      end
      attachments_to_apply = diff[:new_attachments].select do |a|
        selected_attachments.dig(diff[:id].to_s, a[:filename]) == '1'
      end
      note_to_apply = diff[:import_note] if selected_notes[diff[:id].to_s] == '1'

      next if changes_to_apply.empty? && attachments_to_apply.empty? && note_to_apply.blank?

      result = { id: issue.id, applied_fields: [], applied_attachments: [], note_applied: false, errors: [] }

      Issue.transaction do
        journal_text = note_to_apply.presence || l(:text_import_journal_note)
        issue.init_journal(User.current, journal_text)
        result[:note_applied] = note_to_apply.present?

        changes_to_apply.each do |c|
          begin
            apply_field_change(issue, c[:field], c[:raw_new_value])
            result[:applied_fields] << c[:field]
          rescue StandardError => e
            result[:errors] << "#{c[:field]}: #{e.message}"
          end
        end

        unless issue.save
          result[:errors] << issue.errors.full_messages.join(', ')
          raise ActiveRecord::Rollback
        end

        attachments_to_apply.each do |a|
          begin
            add_attachment_to_issue(issue, extract_dir, diff[:id], a[:filename])
            result[:applied_attachments] << a[:filename]
          rescue StandardError => e
            result[:errors] << l(:label_attachment_error, name: a[:filename], message: e.message)
          end
        end
      end

      @results << result
    end
  ensure
    FileUtils.rm_rf(extract_dir) if extract_dir && Dir.exist?(extract_dir)
  end

  # Réécrit, dans le HTML déjà rendu par `textilizable`, tout lien ou
  # source d'image pointant vers une pièce jointe du serveur Redmine en un
  # chemin relatif local vers le fichier réellement présent dans
  # l'archive exportée (../<id_demande>/<nom_fichier>). Sans cela, ces
  # liens pointent vers le serveur Redmine et sont cassés une fois le
  # rapport ouvert hors ligne (ex. file:///.../attachments/download/10/...).
  # Couvre les 3 formats d'URL générés par Redmine pour une pièce jointe :
  #   /attachments/<id>                    (lien "attachment:nom")
  #   /attachments/download/<id>/<nom>     (téléchargement explicite)
  #   /attachments/thumbnail/<id>(/taille) (vignette d'image en ligne)
  # Utilisé pour la description ET les notes de journal, car les images
  # collées au clavier ("![](nom.png)") comme les liens "attachment:nom"
  # génèrent ce type d'URL, que ce soit sur la demande ou sur un
  # commentaire. Retire également "loading=lazy" (ajouté par Redmine sur
  # les images), qui peut empêcher l'affichage d'une image dans un rapport
  # statique ouvert hors ligne ou lors d'un export/impression en PDF (le
  # chargement différé ne se déclenche pas toujours hors navigation
  # normale).
  def localize_attachment_links(html, issue)
    return html if html.blank?

    attachments_by_id = issue.attachments.index_by(&:id)

    result = html.to_s.gsub(%r{(href|src)="[^"]*/attachments/(?:(?:download|thumbnail)/)?(\d+)(?:/[^"?]*)?(?:\?[^"]*)?"}) do
      attr = Regexp.last_match(1)
      attachment_id = Regexp.last_match(2).to_i
      attachment = attachments_by_id[attachment_id]

      if attachment
        %(#{attr}="../#{issue.id}/#{ERB::Util.url_encode(attachment.filename)}")
      else
        Regexp.last_match(0) # pièce jointe non exportée (ex. déjà supprimée) : on laisse le lien tel quel
      end
    end

    result = result.gsub(/\s+loading="lazy"/, '')

    result.html_safe
  end

  # Construit un lien de référence vers une autre demande (parente,
  # sous-tâche ou liée) : un lien d'ancre interne (#issue-<id>) si cette
  # demande fait partie du présent export, sinon un simple texte non
  # cliquable (elle n'existe nulle part dans le rapport, donc aucun lien
  # utilisable ne peut être généré pour un document autonome hors ligne).
  def issue_ref_link(other_issue, report_ids)
    return ''.html_safe if other_issue.nil?

    label = "##{other_issue.id} #{other_issue.subject}"
    if report_ids.include?(other_issue.id)
      %(<a href="#issue-#{other_issue.id}">#{ERB::Util.html_escape(label)}</a>).html_safe
    else
      %(<span class="issue-ref-outside">#{ERB::Util.html_escape(label)} <em>(hors export)</em></span>).html_safe
    end
  end

  private

  # -- Sécurité / autorisations -----------------------------------------

  def find_optional_project
    @project = Project.find(params[:project_id]) if params[:project_id].present?
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def authorize_export
    allowed = User.current.allowed_to?(:export_issues_with_attachments, @project, global: @project.nil?)
    deny_access unless allowed
  end

  # Accès aux écrans d'import : admin, ou membre disposant de la permission
  # "import_issues_from_export" sur au moins un projet. Le filtrage précis
  # des demandes modifiables se fait ensuite demande par demande.
  def authorize_import_access
    allowed = User.current.admin? ||
              User.current.allowed_to?(:import_issues_from_export, nil, global: true)
    deny_access unless allowed
  end

  # Un utilisateur ne peut agir sur une demande que s'il est admin, ou s'il
  # dispose de la permission d'import sur le projet de cette demande précise.
  def issue_import_allowed?(issue)
    User.current.admin? || User.current.allowed_to?(:import_issues_from_export, issue.project)
  end

  def plugin_setting(key)
    Setting.plugin_redmine_issue_export_import[key]
  end

  def redirect_to_referer_or(default_path)
    redirect_to(request.referer.presence || default_path)
  end

  # Chemin du répertoire de travail pour un token donné. Le token est
  # généré côté serveur (SecureRandom.hex) et validé strictement ici afin
  # d'exclure toute tentative de traversée de répertoire.
  def import_tmp_dir(token)
    return nil unless token =~ /\A[a-f0-9]{32}\z/
    File.join(IMPORT_TMP_ROOT, token)
  end

  def cleanup_stale_import_dirs
    return unless Dir.exist?(IMPORT_TMP_ROOT)
    Dir.children(IMPORT_TMP_ROOT).each do |name|
      dir = File.join(IMPORT_TMP_ROOT, name)
      next unless Dir.exist?(dir)
      begin
        FileUtils.rm_rf(dir) if File.mtime(dir) < IMPORT_TOKEN_MAX_AGE.ago
      rescue StandardError => e
        Rails.logger.warn("[redmine_issue_export_import] cleanup error on #{dir}: #{e.message}")
      end
    end
  end

  # -- Construction de la requête (identique à la page de résultats) -----

  def retrieve_query
    if params[:query_id].present?
      @query = IssueQuery.find(params[:query_id])
      @query.project = @project
    else
      @query = IssueQuery.new(name: '_')
      @query.project = @project
      @query.build_from_params(params)
    end
    @query.user = User.current
  end

  # -- Export : colonnes ---------------------------------------------------

  def build_export_columns(query)
    # Colonnes réellement sélectionnées dans la requête à l'écran
    # (query.columns), sans la colonne id (ajoutée systématiquement en
    # première position).
    query.columns.reject { |c| c.name.to_s == 'id' }
  end

  # Construit l'archive zip en mémoire : répertoire de travail temporaire
  # (auto-nettoyé), CSV + pièces jointes, compression, puis lecture des
  # octets avant suppression des fichiers temporaires (aucun fichier ne
  # reste sur le disque du serveur après l'appel).
  def build_export_zip(issues, columns, query = nil)
    query ||= @query
    zip_bytes = nil
    Dir.mktmpdir('issue_export_import_') do |work_dir|
      write_csv(File.join(work_dir, 'issues.csv'), issues, columns)
      copy_attachments(issues, work_dir)
      build_report(work_dir, issues, query, columns)

      zip_tmp = Tempfile.new(['issue_export_import_', '.zip'])
      zip_tmp.close
      begin
        build_zip(work_dir, zip_tmp.path)
        zip_bytes = File.binread(zip_tmp.path)
      ensure
        zip_tmp.unlink
      end
    end
    zip_bytes
  end

  # Génère, dans un sous-répertoire "rapport/" séparé des répertoires de
  # pièces jointes par numéro de demande (afin de ne jamais être confondu
  # avec une pièce jointe lors du ré-import), un **unique** fichier HTML
  # autonome regroupant toutes les demandes exportées : sommaire (avec
  # groupement si la requête en définit un), puis une section par demande
  # (attributs, relations, description, pièces jointes, historique
  # complet), pensé pour être imprimé, exporté en PDF ou projeté en
  # réunion. Le rendu du texte (description, notes) utilise le moteur de
  # formatage de Redmine (textilizable), identique à l'affichage habituel
  # dans l'interface. Les notes marquées "privées" sont systématiquement
  # exclues, ce rapport étant destiné à pouvoir être transmis à des
  # personnes externes.
  def build_report(work_dir, issues, query, columns = nil)
    report_dir = File.join(work_dir, 'rapport')
    FileUtils.mkdir_p(report_dir)

    report_ids = issues.map(&:id)
    journals_by_issue_id = {}
    issues.each { |i| journals_by_issue_id[i.id] = visible_journals_for(i) }

    export_columns = columns || build_export_columns(query)

    File.write(
      File.join(report_dir, 'rapport.html'),
      render_to_string(template: 'issue_export_import/report', layout: false,
                        locals: {
                          issues: issues,
                          groups: build_groups(query, issues),
                          report_ids: report_ids,
                          journals_by_issue_id: journals_by_issue_id,
                          export_columns: export_columns,
                          query: query,
                          sort_criteria: query.sort_criteria,
                          filters: query.filters
                        })
    )
  end

  # Helpers pour le rapport : caption et valeur d'une colonne pour l'affichage HTML
  def column_caption(column)
    if column.respond_to?(:caption)
      # caption peut être un Symbol (ex: :field_status) ou une String
      c = column.caption
      c.is_a?(Symbol) ? l(c) : c.to_s
    elsif column.is_a?(QueryCustomFieldColumn)
      column.custom_field.name
    else
      l("field_#{column.name}", default: column.name.to_s.humanize)
    end
  rescue
    column.name.to_s
  end
  helper_method :column_caption

  def column_display_value(issue, column)
    v = column.value(issue)
    if v.is_a?(Array)
      v.map { |e| scalar_to_s(e) }.join(', ')
    else
      scalar_to_s(v)
    end
  end
  helper_method :column_display_value

  def sort_criteria_to_s(query)
    return '' unless query.sort_criteria.present?
    query.sort_criteria.map do |field, order|
      col = query.available_columns.detect { |c| c.name.to_s == field.to_s }
      name = col ? column_caption(col) : field.to_s
      "#{name} #{order == 'desc' ? '▼' : '▲'}"
    end.join(', ')
  end
  helper_method :sort_criteria_to_s

  def filters_to_s(query)
    return '' unless query.filters.present?
    query.filters.map do |field, opts|
      op = opts[:operator]
      vals = opts[:values]
      col = query.available_columns.detect { |c| c.name.to_s == field.to_s } || query.available_inline_columns.detect { |c| c.name.to_s == field.to_s }
      caption = col ? column_caption(col) : field.to_s
      "#{caption} #{op} #{vals.join(', ')}" rescue "#{field}"
    end.join(' | ')
  end
  helper_method :filters_to_s

  # Regroupement du sommaire du rapport, reflétant le groupement éventuel
  # défini sur la requête ("Group results by" côté Redmine). Retourne nil
  # si la requête n'est pas groupée, sinon une liste ordonnée de paires
  # [libellé_du_groupe, demandes]. L'ordre des groupes suit leur ordre de
  # première apparition dans `issues` (approximation raisonnable ; un tri
  # strictement identique à celui de Redmine — ex. par position pour les
  # priorités — n'est pas reproduit ici).
  def build_groups(query, issues)
    return nil unless query.respond_to?(:grouped?) && query.grouped?

    column = query.group_by_column
    return nil unless column

    groups = {}
    order = []

    issues.each do |issue|
      value = column.value(issue)
      label = if value.is_a?(Array)
                value.map { |v| scalar_to_s(v) }.join(', ')
              else
                scalar_to_s(value)
              end
      label = label.presence || l(:label_group_none)

      unless groups.key?(label)
        groups[label] = []
        order << label
      end
      groups[label] << issue
    end

    order.map { |label| [label, groups[label]] }
  end

  # Historique visible pour un rapport externe : on exclut entièrement les
  # journaux marqués "notes privées" (et non uniquement leur texte), pour
  # rester cohérent avec la façon dont Redmine masque ces entrées aux
  # utilisateurs non autorisés.
  def visible_journals_for(issue)
    issue.journals.includes(:user, :details).order(:created_on).reject(&:private_notes?)
  end

  def build_zip(source_dir, zip_path)
    FileUtils.rm_f(zip_path)
    Zip::File.open(zip_path, Zip::File::CREATE) do |zipfile|
      Dir.glob(File.join(source_dir, '**', '*')).each do |path|
        next if File.directory?(path)
        entry_name = path.sub("#{source_dir}#{File::SEPARATOR}", '')
        zipfile.add(entry_name, path)
      end
    end
  end

  def write_csv(path, issues, columns)
    sep = plugin_setting('csv_separator').presence || ';'
    headers = ['id'] + columns.map { |c| csv_header(c) } + [import_note_header]
    File.open(path, 'wb') do |f|
      f.write("\xEF\xBB\xBF") # BOM UTF-8 pour compatibilité Excel
      f.write(CSV.generate_line(headers, col_sep: sep))
      issues.each do |issue|
        row = [issue.id] + columns.map { |c| csv_value(issue, c) } + ['']
        f.write(CSV.generate_line(row, col_sep: sep))
      end
    end
  end

  # En-tête (traduit) de la colonne de commentaire d'import. Le suffixe
  # technique "[import_note]" reste constant quelle que soit la langue de
  # l'utilisateur qui exporte ou importe, pour une détection fiable dans
  # compute_diffs indépendamment de la langue.
  def import_note_header
    "#{l(:label_import_note_column)} #{IMPORT_NOTE_SUFFIX}"
  end

  # En-tête stable : pour les champs standards, le nom technique de la colonne
  # (ex: "status", "assigned_to"). Pour les champs personnalisés, on ajoute
  # l'identifiant technique entre crochets afin de fiabiliser le ré-import
  # même si le libellé du champ est modifié entre-temps (ex: "Origine [cf_5]").
  def csv_header(column)
    if column.is_a?(QueryCustomFieldColumn)
      "#{column.custom_field.name} [cf_#{column.custom_field.id}]"
    else
      column.name.to_s
    end
  end

  def csv_value(issue, column)
    value = column.value(issue)
    if value.is_a?(Array)
      value.map { |v| scalar_to_s(v) }.join(', ')
    else
      scalar_to_s(value)
    end
  end

  def scalar_to_s(value)
    case value
    when NilClass then ''
    when Time, DateTime then format_time(value)
    when Date then format_date(value)
    when TrueClass then '1'
    when FalseClass then '0'
    when Float then value.to_s
    else value.to_s
    end
  end

  # -- Export : pièces jointes ---------------------------------------------

  def copy_attachments(issues, full_path)
    issues.each do |issue|
      next if issue.attachments.blank?
      issue_dir = File.join(full_path, issue.id.to_s)
      FileUtils.mkdir_p(issue_dir)
      issue.attachments.each do |attachment|
        source = attachment.diskfile
        next unless source && File.exist?(source)
        dest = File.join(issue_dir, attachment.filename)
        FileUtils.cp(source, dest)
      end
    end
  end

  # -- Import : extraction du zip déposé -----------------------------------

  def extract_zip(zip_path, dest_dir)
    Zip::File.open(zip_path) do |zip_file|
      zip_file.each do |entry|
        dest_path = File.join(dest_dir, entry.name)

        # Protection "zip slip" : refuse toute entrée qui sortirait du
        # répertoire de destination (ex. chemins contenant "../").
        unless File.expand_path(dest_path).start_with?("#{File.expand_path(dest_dir)}#{File::SEPARATOR}")
          raise "entrée de zip invalide : #{entry.name}"
        end

        if entry.directory?
          FileUtils.mkdir_p(dest_path)
        else
          FileUtils.mkdir_p(File.dirname(dest_path))
          entry.extract(dest_path) { true } # true => écrase si déjà présent
        end
      end
    end
  end

  # -- Import : lecture du CSV et calcul des différences -------------------

  # Détermine le séparateur à utiliser pour lire le CSV importé. Un
  # tableur (Excel, LibreOffice) peut ré-enregistrer le fichier avec un
  # séparateur différent de celui configuré dans le plugin (typiquement la
  # virgule au lieu du point-virgule, selon les paramètres régionaux) : si
  # le séparateur configuré ne permet pas de retrouver une colonne "id"
  # dans l'en-tête, on essaie automatiquement les séparateurs courants
  # (virgule, point-virgule, tabulation) et on retient le premier qui
  # fonctionne, plutôt que de faire échouer l'import silencieusement.
  def detect_csv_separator(csv_file)
    configured = plugin_setting('csv_separator').presence || ';'
    candidates = [configured, ',', ';', "\t"].uniq

    first_line = begin
      File.open(csv_file, 'r:bom|utf-8') { |f| f.readline }
    rescue StandardError
      nil
    end
    return configured if first_line.blank?

    first_line = first_line.chomp

    candidates.each do |sep|
      begin
        headers = CSV.parse_line(first_line, col_sep: sep)
        return sep if headers && headers.include?('id')
      rescue StandardError
        next
      end
    end

    configured
  end

  # Retourne { diffs: [...], skipped_count: N } où skipped_count est le
  # nombre de lignes ignorées car sans identifiant de demande valide
  # (colonne "id" vide, ou identifiant ne correspondant à aucune demande
  # existante). Le plugin ne sait pas créer de nouvelles demandes : ces
  # lignes ne sont donc jamais appliquées, mais elles ne doivent pas non
  # plus disparaître silencieusement — l'appelant est responsable
  # d'afficher ce compteur à l'utilisateur (voir preview.html.erb).
  def compute_diffs(export_path, csv_file)
    sep = detect_csv_separator(csv_file)
    rows = CSV.read(csv_file, col_sep: sep, headers: true, encoding: 'bom|utf-8')

    diffs = []
    skipped_count = 0

    rows.each do |row|
      issue_id = row['id'].to_s.strip
      if issue_id.blank?
        skipped_count += 1
        next
      end

      issue = Issue.find_by(id: issue_id)
      if issue.nil?
        skipped_count += 1
        next
      end

      changes = []
      import_note = nil

      row.headers.each do |header|
        next if header.nil? || header == 'id'

        if header.to_s.strip.end_with?(IMPORT_NOTE_SUFFIX)
          note_text = row[header].to_s
          import_note = note_text if note_text.present?
          next
        end

        new_raw = row[header].to_s
        field_key, current_display = current_value_for_header(issue, header)
        next if field_key.nil? # en-tête non reconnu : on ignore silencieusement

        if current_display.to_s.strip != new_raw.strip
          changes << {
            field: field_key,
            header: header,
            old_value: current_display,
            new_value: new_raw,
            raw_new_value: new_raw
          }
        end
      end

      issue_dir = File.join(export_path, issue_id)
      new_attachments = []
      if Dir.exist?(issue_dir)
        existing_names = issue.attachments.map(&:filename)
        Dir.children(issue_dir).sort.each do |fname|
          next if existing_names.include?(fname)
          new_attachments << { filename: fname, full_path: File.join(issue_dir, fname) }
        end
      end

      next if changes.empty? && new_attachments.empty? && import_note.blank?

      diffs << {
        id: issue.id,
        subject: issue.subject,
        changes: changes,
        new_attachments: new_attachments,
        import_note: import_note
      }
    end

    { diffs: diffs, skipped_count: skipped_count }
  end

  # Retourne [clé_technique_du_champ, valeur_actuelle_affichable] pour un
  # en-tête CSV donné, ou [nil, nil] si l'en-tête n'est pas reconnu.
  def current_value_for_header(issue, header)
    if header =~ /\[cf_(\d+)\]\z/
      cf_id = Regexp.last_match(1).to_i
      cfv = issue.custom_field_value(cf_id)
      return ["cf_#{cf_id}", cfv.to_s]
    end

    return [nil, nil] unless CORE_COLUMNS.include?(header)

    value =
      case header
      when 'tracker'        then issue.tracker&.name
      when 'status'          then issue.status&.name
      when 'priority'        then issue.priority&.name
      when 'subject'         then issue.subject
      when 'description'     then issue.description
      when 'author'          then issue.author&.to_s
      when 'assigned_to'     then issue.assigned_to&.to_s
      when 'category'        then issue.category&.name
      when 'fixed_version'   then issue.fixed_version&.name
      when 'start_date'      then issue.start_date&.iso8601
      when 'due_date'        then issue.due_date&.iso8601
      when 'done_ratio'      then issue.done_ratio.to_s
      when 'estimated_hours' then issue.estimated_hours.to_s
      end

    [header, value]
  end

  # -- Import : application d'un changement --------------------------------

  def apply_field_change(issue, field_key, raw_value)
    if field_key.start_with?('cf_')
      cf_id = field_key.sub('cf_', '').to_i
      issue.custom_field_values = { cf_id => raw_value }
      return
    end

    case field_key
    when 'tracker'
      t = issue.project.trackers.find_by(name: raw_value)
      raise "tracker '#{raw_value}' introuvable pour ce projet" if t.nil?
      issue.tracker = t
    when 'status'
      s = IssueStatus.find_by(name: raw_value)
      raise "statut '#{raw_value}' introuvable" if s.nil?
      issue.status = s
    when 'priority'
      p = IssuePriority.find_by(name: raw_value)
      raise "priorité '#{raw_value}' introuvable" if p.nil?
      issue.priority = p
    when 'subject'
      issue.subject = raw_value
    when 'description'
      issue.description = raw_value
    when 'assigned_to'
      issue.assigned_to = find_principal(issue.project, raw_value)
    when 'category'
      issue.category = raw_value.blank? ? nil : issue.project.issue_categories.find_by(name: raw_value)
    when 'fixed_version'
      issue.fixed_version = raw_value.blank? ? nil : issue.project.shared_versions.find_by(name: raw_value)
    when 'start_date'
      issue.start_date = raw_value.blank? ? nil : Date.parse(raw_value)
    when 'due_date'
      issue.due_date = raw_value.blank? ? nil : Date.parse(raw_value)
    when 'done_ratio'
      issue.done_ratio = raw_value.to_i
    when 'estimated_hours'
      issue.estimated_hours = raw_value.blank? ? nil : raw_value.to_f
    else
      raise "champ '#{field_key}' non pris en charge en import"
    end
  end

  def find_principal(project, name_or_login)
    return nil if name_or_login.blank?
    project.principals.detect { |p| p.to_s == name_or_login || (p.respond_to?(:login) && p.login == name_or_login) }
  end

  def add_attachment_to_issue(issue, extract_dir, issue_id_str, filename)
    full_file_path = File.join(extract_dir, issue_id_str, filename)
    raise "fichier introuvable: #{full_file_path}" unless File.exist?(full_file_path)

    File.open(full_file_path, 'rb') do |file|
      attachment = Attachment.create(
        container: issue,
        file: file,
        author: User.current,
        filename: filename
      )
      raise attachment.errors.full_messages.join(', ') unless attachment.persisted? && attachment.errors.empty?
    end
  end
end
