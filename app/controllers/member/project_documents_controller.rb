# frozen_string_literal: true

module Member
  # Documenti di un progetto (tab Documents): lista/download per chi vede il progetto;
  # upload/rinomina/eliminazione gated da `documents.manage`. Scoping anti-BOLA al progetto.
  # Controller flat (non Member::Projects::*) per non ombreggiare il namespace ::Projects (model).
  class ProjectDocumentsController < Member::BaseController
    permission_not_required "Elenco dei documenti di un progetto visibile: sola lettura, caricare e togliere sono " \
                            "gated più sotto.",
                            only: %i[index]

    # Sortable#sorted whitelist; type and size live on the file's blob. CYRA-883
    BLOB = { file_attachment: :blob }.freeze
    SORT_COLUMNS = {
      "title" => "LOWER(projects_documents.title)",
      "type" => { expr: "active_storage_blobs.content_type", joins: BLOB },
      "size" => { expr: "active_storage_blobs.byte_size", joins: BLOB },
      "uploaded" => :created_at
    }.freeze

    before_action :set_project
    before_action :require_management, only: %i[create edit update destroy]
    before_action :set_document, only: %i[edit update destroy]

    # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
    remembers_filters :tag, :q, only: :index

    def index
      @pagination = paginate(sorted(filtered_documents, columns: SORT_COLUMNS))
      @documents = @pagination.records
      @tag_options = ::Projects::Document.distinct_tags(@project.documents)
      # Viste salvate del SOLO progetto corrente (le viste documents sono nested al progetto:
      # mostrarne di altri progetti applicherebbe un project_id diverso e navigherebbe altrove).
      @saved_views = saved_views_for("documents").where("filters->>'project_id' = ?", @project.id)
      @stats = @project.ticket_tally
    end

    def create
      result = ::Projects::Documents::Upload.call(project: @project, files: params[:files],
                                                  actor: Current.account, true_actor: Current.true_account)
      if result.ok?
        redirect_to member_project_documents_path(@project),
                    notice: t("member.documents.uploaded", count: result.value.length)
      else
        redirect_to member_project_documents_path(@project), alert: result.error.message
      end
    end

    def edit
      @stats = @project.ticket_tally
      load_activity_log
    end

    def update
      result = ::Projects::Documents::Save.call(document: @document, attributes: document_params,
                                                actor: Current.account, true_actor: Current.true_account)
      if result.ok?
        redirect_to member_project_documents_path(@project), notice: t("member.documents.updated")
      else
        @errors = result.error.details || {}
        @stats = @project.ticket_tally
        # Anche il re-render dopo un errore passa da `edit`, che rende il modale della cronologia:
        # senza questi il template esplode su nil invece di mostrare il messaggio di validazione.
        load_activity_log
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      @document.destroy
      redirect_to member_project_documents_path(@project), notice: t("member.documents.deleted")
    end

    private

    # Anti-BOLA + scoping: progetto non visibile (altra org o non assegnato) → RecordNotFound.
    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    def set_document
      @document = @project.documents.find(params[:id])
    end

    # Activity-log generalizzato: blocco Audit (ultimo evento) + cronologia nel modale.
    def load_activity_log
      @activity_events = @document.activity_events.chronological.includes(:actor, :true_actor).to_a
      @last_activity = @activity_events.last
    end

    def filtered_documents
      scope = @project.documents.ordered.with_attached_file.includes(:created_by)
      scope = scope.tagged_any(filter_ids(:tag)) if filter_ids(:tag).any?
      scope = scope.search(search_q) if search_q.present?
      scope
    end

    # Tag come testo separato da virgole (il model normalizza strip/downcase/uniq).
    def document_params
      { title: params[:title], description: params[:description],
        tags: params[:tags].to_s.split(",") }
    end


    def require_management
      require_permission!("documents.manage", scope: @project)
    end
  end
end
