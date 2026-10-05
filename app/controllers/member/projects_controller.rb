# frozen_string_literal: true

module Member
  # CRUD progetti dell'organizzazione corrente. Lettura (index/show) per tutti i membri;
  # gestione (new/create/edit/update/destroy) per admin/owner. Scoping anti-BOLA all'org.
  class ProjectsController < Member::BaseController
    permission_not_required "Elenco e scheda dei progetti visibili: sola lettura, creare e modificare sono gated " \
                            "più sotto.",
                            only: %i[index show history]

    # Whitelist ordinamento (contratto Sortable#sorted). tickets/open = subquery COUNT
    # correlate (nessun counter cache su projects): il costo si paga SOLO quando quella
    # colonna è attiva. "open" ordina per i ticket "Da fare" (categoria open, non il code
    # letterale) — coerente col conteggio mostrato nella colonna (CYRA-358).
    SORT_COLUMNS = {
      "name" => "LOWER(projects.name)",
      "key" => :key,
      "description" => "LOWER(projects.description)",
      "group" => { expr: "LOWER(projects_groups.name)", joins: :group },
      "tickets" => "(SELECT COUNT(*) FROM ticketing_tickets t WHERE t.project_id = projects.id)",
      "open" => "(SELECT COUNT(*) FROM ticketing_tickets t " \
                "JOIN types_ticket_statuses s ON s.id = t.status_id " \
                "AND s.category = #{Types::TicketStatus.categories[:open]} " \
                "WHERE t.project_id = projects.id)",
      # CYRA-883 — the sort menu of the search bar: most open errors, latest release.
      "errors" => "(SELECT COUNT(*) FROM errors_groups g WHERE g.project_id = projects.id " \
                  "AND g.status = #{Errors::Group.statuses[:unresolved]})",
      "release" => "(SELECT MAX(r.created_at) FROM projects_releases r WHERE r.project_id = projects.id)"
    }.freeze

    # Densità della card ticket nella show progetto (CYRA-12): la lista era illimitata (scope.to_a),
    # su progetti grossi cresceva senza controllo. Paginata con Ui::PaginationComponent.
    TICKETS_PER_PAGE = 15

    # CYRA-827 — i due confini di caricamento della scheda progetto. La panoramica mette insieme la
    # lista ticket, la fascia di salute, gli ambienti, i rilasci, gli strumenti, l'uptime e la
    # cronologia: sfogliare i ticket ricostruiva tutto, e la cronologia veniva materializzata per
    # intero a ogni cambio pagina. Ora la lista vive nel suo frame — che chiede solo se stessa — e la
    # cronologia si carica su richiesta, a pagine, dalla propria action.
    TICKETS_FRAME = "project-tickets-results"
    HISTORY_FRAME = "project-history"
    # Venticinque righe: una cronologia si legge a scorrimento, non a colpo d'occhio come una tabella.
    HISTORY_PER_PAGE = 25
    # The overview shows the last releases; "See all" opens up to RELEASES_IN_DIALOG of them.
    RELEASES_IN_PANEL = 3
    RELEASES_IN_DIALOG = 50

    before_action :set_project, only: %i[show edit update destroy history]
    before_action :require_create, only: %i[new create]
    before_action :require_manage_project, only: %i[edit update destroy]
    before_action :load_platforms, only: %i[new create edit update]
    before_action :load_environments, only: %i[new create edit update]
    before_action :load_groups, only: %i[new create edit update]

    # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
    remembers_filters :platform_id, :group_id, :health, :q, only: :index

    def index
      @projects_view = projects_view_preference
      @platforms = Current.organization.platforms.ordered.to_a
      @filter_groups = visible.groups.ordered.to_a
      # with_attached_icon_image: la lista renderizza l'icona (EntityMark) per progetto → senza preload
      # un active_storage_attachments per riga (prosopite N+1 su liste lunghe).
      scope = visible.projects.includes(:group, :github_repository).with_attached_icon_image.order(:name)
      scope = scope.where("projects.name ILIKE :q OR projects.key ILIKE :q", q: "%#{search_q}%") if search_q.present?
      if filter_ids(:platform_id).any?
        # Subselect (niente joins+distinct): SELECT DISTINCT + ORDER BY su espressione fuori
        # dalla select list è un errore PG — e qui l'ordine è dinamico (subquery COUNT).
        scope = scope.where(id: Connections::ProjectPlatform
                                  .where(platform_id: filter_ids(:platform_id)).select(:project_id))
      end
      scope = scope.where(group_id: filter_ids(:group_id)) if filter_ids(:group_id).any?
      scope = with_problems(scope) if params[:health] == "problems"
      sorted_scope = sorted(scope, columns: SORT_COLUMNS)
      if @projects_view == "table"
        @pagination = paginate(sorted_scope)
        @projects = @pagination.records
      else
        # Cards show every project, grouped or not: a group cut after twelve looked complete.
        # Grouping (D20) is a View choice: `grouped=none` drops the group headings.
        @cards_grouped = params[:grouped] != "none"
        @projects = sorted_scope.to_a
        @card_health = ::Projects::CardHealth.new(@projects)
      end
      # Chip e toolbar contano su TUTTO lo scope (non sulla pagina): coerenti tra loro e col numero
      # di card mostrate. @pagination esiste solo nel ramo table (lì lo usa il pager).
      @projects_total = scope.count
      load_empty_groups(scope, filtering: search_q.present? || filter_ids(:platform_id).any? || filter_ids(:group_id).any? ||
                                           params[:health].present?)
      ids = scope.ids
      @ticket_totals = Ticketing::Ticket.where(project_id: ids).group(:project_id).count
      # Conteggi per categoria per progetto (Da fare / In corso / …): stessa definizione della pagina
      # progetto, così il numero "Da fare" in lista coincide col dettaglio (CYRA-358).
      @ticket_counts = Ticketing::Tally.by_project(Ticketing::Ticket.where(project_id: ids))
    end

    # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
    remembers_filters :status_id, :priority_id, :assignee_id, :q, :sort, only: :show

    def show
      # CYRA-827 — sfogliare i ticket è una domanda sulla LISTA, non sulla scheda. Quando la richiesta
      # arriva dal frame della lista si esce prima di calcolare cronologia, aggregati e raccolte: il
      # browser di quel pezzo butterebbe via tutto il resto, ma il database l'avrebbe già letto.
      return render_tickets_frame if turbo_frame_request_id == TICKETS_FRAME

      @stats = @project.ticket_tally

      # ID degli status "non chiusi" (categoria da fare + in corso) per il link della card salute
      # "Non chiusi" (CYRA-358): la lista ticket filtra per status_id (UUID). where.not(:done) tiene
      # dentro anche "in revisione" e gli status personalizzati dell'org, che il vecchio filtro per
      # code [open, in_progress] saltava; ordered dà un ordine stabile per position.
      unresolved = Current.organization.ticket_statuses.where.not(category: :done).ordered.pluck(:category, :id)
      @unresolved_status_ids = unresolved.map(&:last)
      # The to-do and in-progress counts in the Tickets title link to the list filtered on them (CYRA-883).
      @status_ids_by_category = unresolved.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }

      load_tickets_list

      # Panoramica in SOLA LETTURA (CYRA-63): striscia environment dichiarati + conteggi token. La
      # gestione (dichiarazione, capability tri-state, server) vive nella tab Environments.
      @project_environments = @project.environments.ordered.to_a
      @environment_token_counts = @project.tokens.active.group(:environment_id).count

      # L'uptime ha senso solo su piattaforme web/server: i progetti solo-mobile non mostrano la sezione
      # (e non calcoliamo le query relative). Vedi Projects::Project#supports_uptime?.
      @supports_uptime = @project.supports_uptime?

      # Recent releases (from CI or inferred from error ingest): the panel shows the first
      # RELEASES_IN_PANEL, "See all" opens the rest.
      @releases = @project.releases.recent.limit(RELEASES_IN_DIALOG).to_a

      # Card "Monitoring tools": fonti OSSERVATE dall'ingest (auto, ultima versione vista) con stato e
      # link alla cronologia versioni (CYRA-64). Fully-qualified per non ombreggiare ::Projects.
      @tools_overview = ::Projects::ToolsOverview.new(@project)
      if @supports_uptime
        # 1 monitor per env: monitor per env + % 24h + blocchi 24h (query batch). Sola lettura: la
        # gestione monitor/server è nella tab Environments (Member::ProjectEnvironmentsController).
        @uptime_monitors = @project.uptime_monitors.includes(:environment).index_by(&:environment_id)
        monitor_ids = @uptime_monitors.values.map(&:id)
        @uptime_percents = Uptime::Monitor.uptime_percents(monitor_ids, 24.hours.ago)
        @uptime_buckets = Uptime::Monitor.buckets_for(monitor_ids, "24h")
      end

      # Fascia "salute" (dashboard overview): numeri a colpo d'occhio dai domini già presenti.
      load_health_overview

      # Activity-log generalizzato: nel blocco Audit ci sta l'ULTIMO evento, e basta quello. La
      # cronologia intera arriva dal frame di #history, a pagine (CYRA-827): materializzarla qui
      # significava rileggere tutto lo storico del progetto anche solo per cambiare pagina ai ticket.
      @last_activity = @project.activity_events
                               .reorder(created_at: :desc, id: :desc).includes(:actor, :true_actor).first

      direct_book_ids = ::Connections::BookProject.where(project_id: @project.id).select(:book_id)
      @project_books = ::Knowledge::Book.where(id: direct_book_ids)
      if @project.group_id
        group_book_ids = ::Connections::BookGroup.where(group_id: @project.group_id).select(:book_id)
        @project_books = @project_books.or(::Knowledge::Book.where(id: group_book_ids))
      end
      @project_books = @project_books.includes(:projects, { groups: :projects }).ordered.to_a
      @visible_project_ids = visible.projects.ids.to_set
      @visible_group_ids = visible.groups.ids.to_set
    end

    # CYRA-827 — la cronologia del progetto, chiesta quando serve. Il riquadro della panoramica la
    # carica pigramente nel proprio frame; lo stesso indirizzo aperto da solo è una pagina intera, ed
    # è la via di recupero quando il frame non arriva (rete caduta, sessione scaduta: lì Turbo porta
    # alla login a schermo intero invece di lasciare un pannello muto).
    def history
      @history = Pagination.call(
        @project.activity_events.reorder(created_at: :desc, id: :desc).includes(:actor, :true_actor),
        page: params[:page], per: requested_per(HISTORY_PER_PAGE)
      )
      return render(partial: "member/projects/history_frame", layout: false) if turbo_frame_request?

      render :history
    end

    # F016 — what a card paints red (Projects::CardHealth): open errors, or an active monitor that is down.
    def with_problems(scope)
      scope.where(id: Errors::Group.status_unresolved.select(:project_id))
           .or(scope.where(id: Uptime::Monitor.active.status_down.select(:project_id)))
    end

    # Visible groups without projects: listed in one row under the cards so none disappears
    # (CYRA-362, CYRA-883). Not with an active filter: they have nothing to do with it.
    # `reorder(nil)`: SELECT DISTINCT cannot ORDER BY a column outside the select list (PG error).
    def load_empty_groups(scope, filtering:)
      represented_ids = scope.reorder(nil).where.not(group_id: nil).distinct.pluck(:group_id)
      @empty_groups = if filtering
                        []
      else
                        visible.groups.where.not(id: represented_ids)
                                              .with_attached_icon_image.ordered.to_a
      end
    end

    # Snapshot di salute del progetto per la fascia in cima alla overview. Solo aggregati leggeri
    # (COUNT/istogrammi) sui domini già esistenti: errori (unresolved + istogramma 7g), uptime %
    # 24h medio, volume log 7g, top slow query, conteggi ticket per categoria (già in @stats).
    def load_health_overview
      groups = Errors::Group.where(project_id: @project.id)
      @health_errors_unresolved = groups.status_unresolved.count
      @health_error_buckets = Errors::Group.buckets_for(groups.status_unresolved.pluck(:id), "7d")
                                           .values.map { |b| b.sum { |x| x[:count] } }
      # CYRA-361 — il gruppo di errori più frequente ancora aperto e non già diventato ticket: è da lì
      # che si propone di aprirne uno quando il progetto ha errori e nessun ticket. Una query sola,
      # e solo quando la proposta può davvero comparire.
      @health_top_error_group = groups.status_unresolved.where(ticket_id: nil)
                                      .order(events_count: :desc).first if @stats.total.zero?
      @health_logs_7d = Logs::Entry.where(project_id: @project.id, occurred_at: 7.days.ago..).count
      # CYRA-367 — le tabelle dell'infrastruttura (code, cache, canali) non sono il prodotto: una
      # lentezza lì è rumore del framework in cima alla pagina più vista. Si prende un margine e si
      # filtra in Ruby (il titolo è testo, e riconoscere una tabella non è un lavoro da SQL), poi si
      # dichiara quante righe sono state tolte: l'esclusione non deve essere silenziosa.
      candidates = Metrics::Group.where(project_id: @project.id).kind_slow_query
                                 .order(Arel.sql("duration_total_ms / NULLIF(samples_count,0) DESC"))
                                 .limit(12).to_a
      @health_slow_queries = candidates.reject { |group| group.query_label.system? }.first(3)
      @health_slow_queries_excluded = candidates.count { |group| group.query_label.system? }
      # CYRA-361 — quanti controlli di disponibilità esistono e quali ambienti ne sono scoperti: sono
      # le condizioni delle proposte, e si contano solo per i progetti che l'uptime lo supportano.
      if @supports_uptime
        monitors = Uptime::Monitor.where(project_id: @project.id)
        @health_monitors_count = monitors.count
        covered = monitors.distinct.pluck(:environment_id).compact
        @environments_without_monitor = @project_environments.to_a.reject { |env| covered.include?(env.id) }
      end
      if @supports_uptime && @uptime_percents&.any?
        vals = @uptime_percents.values.compact
        @health_uptime_avg = vals.any? ? (vals.sum / vals.size).round(2) : nil
      end
      load_first_run_state
    end

    # CYRA-575 — La PRIMA ACCENSIONE: il progetto non ha ancora ticket e non sta ricevendo niente. È
    # l'unico momento in cui i passi di configurazione sono un aiuto invece di un rimprovero fisso —
    # su un progetto vivo che di proposito non usa GitHub, «collega il repository» resterebbe acceso
    # per sempre. Nessuna query in più nel caso normale: i tre numeri sono già in memoria, e GitHub si
    # interroga soltanto quando la proposta può davvero comparire.
    def load_first_run_state
      @first_run = @stats.total.zero? && @health_errors_unresolved.zero? && @health_logs_7d.zero?
      return unless @first_run

      @active_tokens_count = @environment_token_counts.values.sum
      @repository_connectable = @project.github_repository.nil? &&
                                Current.organization.github_installation.present?
    end

    def new
      @project = Current.organization.projects.new
    end

    def create
      @project = Current.organization.projects.new
      if save_project(@project).ok?
        redirect_to member_project_path(@project), notice: t("member.projects.created")
      else
        @errors = @project.errors.to_hash
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      if save_project(@project).ok?
        redirect_to member_project_path(@project), notice: t("member.projects.updated")
      else
        @errors = @project.errors.to_hash
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      Projects::Destroy.call(project: @project)
      redirect_to member_projects_path, notice: t("member.projects.deleted")
    end

    private

    # CYRA-827 — la lista ticket della panoramica e tutto ciò che dal filtro DIPENDE: le righe, il
    # pager e la barra (che porta il conteggio filtrato e i chip attivi). Le opzioni dei tre menu
    # servono a disegnare la barra, quindi stanno qui e non fra gli aggregati della scheda.
    def load_tickets_list
      scope = @project.tickets.with_attached_files.includes(:status, :priority, :assignee)
                      .order(created_at: :desc)
      scope = scope.where(status_id: filter_ids(:status_id))     if filter_ids(:status_id).any?
      scope = scope.where(priority_id: filter_ids(:priority_id)) if filter_ids(:priority_id).any?
      scope = scope.where(assignee_id: filter_ids(:assignee_id)) if filter_ids(:assignee_id).any?
      scope = scope.where("ticketing_tickets.title ILIKE ?", "%#{search_q}%") if search_q.present?
      # Paginazione a TICKETS_PER_PAGE: i link pager preservano q + filtri (Ui::PaginationComponent).
      # CYRA-924 — the same column sort as the Tickets list (C9).
      @pagination = paginate(sorted(scope, columns: Member::Tickets::Listing::SORT_COLUMNS), per: TICKETS_PER_PAGE)
      @tickets = @pagination.records

      @statuses   = Current.organization.ticket_statuses.active.ordered
      @priorities = Current.organization.ticket_priorities.active.ordered
      @assignees  = Current.organization.accounts.order(:name)
    end

    # Il pezzo di pagina, senza il layout: è ciò che rende vero il risparmio invece di limitarlo ai
    # byte che il browser scarta. Il frame porta con sé il proprio guscio, quindi il frammento resta
    # sostituibile anche quando la lista si svuota.
    def render_tickets_frame
      load_tickets_list
      render partial: "member/projects/tickets_frame", layout: false
    end

    # Anti-BOLA + scoping: un id non visibile (altra org o non assegnato a member/customer) →
    # RecordNotFound. owner/admin/god vedono tutto (visible.projects).
    def set_project
      @project = visible.projects.find(params[:id])
    end

    def load_platforms
      @platforms = Current.organization.platforms.active.ordered.to_a
    end

    def load_environments
      @environments = Current.organization.environments.active.ordered.to_a
    end

    def load_groups
      @groups = Current.organization.groups.ordered.to_a
    end

    # Logica di dominio (attributi + dimensioni org-scoped group/platforms/environments) condivisa
    # col canale CLI in `Projects::Save` (`rules/backend-channels.md`): un solo posto, niente duplicazione.
    def save_project(project)
      Projects::Save.call(
        project:, organization: Current.organization, attributes: project_params,
        actor: Current.account, true_actor: Current.true_account, group_id: params[:group_id],
        platform_ids: params[:platform_ids], environment_ids: params[:environment_ids]
      )
    end

    def project_params
      params.permit(:name, :key, :color, :description, :icon, :icon_image,
                    :quick_bug_report_enabled, :secret_approval_enabled)
    end

    def require_create
      require_permission!("projects.create")
    end

    def require_manage_project
      key = action_name == "destroy" ? "projects.delete" : "projects.edit"
      require_permission!(key, scope: @project)
    end
  end
end
