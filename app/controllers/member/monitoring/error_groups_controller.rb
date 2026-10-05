# frozen_string_literal: true

module Member
  module Monitoring
    # Error monitoring (UI Member). Lettura per chiunque veda i progetti (scoping
    # visible.error_groups, anti-BOLA); triage e promote a ticket per admin/owner.
    class ErrorGroupsController < Member::BaseController
      permission_not_required "Leggere gli errori dei progetti visibili: il confine è la visibilità; triage e " \
                              "fusione sono gated più sotto.",
                              only: %i[index knowledge replay]

      # Pannello «Conoscenza correlata» della show (azione #knowledge), condiviso col ticket.
      include Member::KnowledgeRelatedPanel
      # CYRA-800 — il gruppo dell'indirizzo e chi può metterci le mani: gli stessi dello smistamento.
      include ErrorGroupScoping
      # CYRA-737 — la base condivisa delle pagine-elenco dell'area di controllo; da lì arriva anche
      # il periodo (CYRA-340), lo stesso di prestazioni e log, ricordato fra le pagine.
      include Indexable

      # Whitelist ordinamento (contratto Sortable#sorted). level è enum int (severità in
      # ordine di dichiarazione); events/users sono contatori denormalizzati.
      # CYRA-924 — the occurrences of one error sort on every column (C9).
      OCCURRENCE_SORT_COLUMNS = {
        "when" => :occurred_at,
        "environment" => "LOWER(errors_events.environment)",
        "release" => "LOWER(errors_events.release)",
        "level" => :level,
        "event" => :event_id
      }.freeze

      SORT_COLUMNS = {
        "issue" => "LOWER(errors_groups.title)",
        "level" => :level,
        "status" => :status,
        "events" => :events_count,
        "users" => :users_count,
        "last_seen" => :last_seen_at
      }.freeze

      # Cap di log correlati mostrati per singola occorrenza (per trace_id), applicato a livello DB.
      RELATED_LOGS_PER_OCCURRENCE = 20

      # Solo sull'elenco: lì il periodo è una SCELTA. Nel dettaglio `from`/`to` sono il blocco
      # cliccato sull'istogramma — un drill-down locale, che non deve diventare il periodo di tutta
      # l'area (si tornerebbe all'elenco ristretti a dieci minuti senza aver chiesto niente).
      monitoring_time_range
      # CYRA-694 — i filtri, DOPO il periodo: se entrambi vanno ripristinati, il primo redirect
      # ferma la catena e il secondo riparte con la query già arricchita (al più due, poi converge).
      # `from`/`to` restano di TimeRangeable: qui solo i filtri veri.
      remembers_filters :status, :level, :handled, :environment, :project_id, :q, :sort, only: :index
      before_action :set_group, only: %i[show promote similar knowledge replay assign destroy]
      before_action :require_triage_role, only: %i[promote similar]
      # CYRA-192: fondere ed eliminare distruggono dati e non si annullano → chiave PROPRIA
      # (errors.destroy, di Maintainer), non errors.triage che il ruolo «Triager» ha già per smistare.
      before_action -> { require_permission!("errors.destroy", scope: @group.project) }, only: :destroy
      # CYRA-153: assegnare è una chiave PROPRIA (reversibile, non distruttiva), separata dal triage.
      before_action -> { require_permission!("errors.assign", scope: @group.project) }, only: :assign

      def index
        scope = visible.error_groups.includes(:project, :ticket).recent
        # CYRA-375 — l'ambiente vive sull'OCCORRENZA, non sul gruppo: un gruppo può aver colpito sia
        # la prova sia il sito vero. Il filtro seleziona i gruppi con ALMENO un'occorrenza
        # nell'ambiente scelto (è la domanda che si fa chi filtra: "questo ha toccato la produzione?").
        scope = filter_by_environment(scope)
        scope = scope.where(status: status_filter) if status_filter.any?
        scope = scope.where(level: level_filter) if level_filter.any?
        scope = scope.where(has_unhandled: true) if unhandled_only_filter?
        scope = filter_by_project(scope)
        scope = filter_by_search(scope, "errors_groups.title", "errors_groups.culprit")
        # CYRA-340 — la finestra di tempo, la stessa di prestazioni e log: «cos'è successo nell'ultima
        # ora» ha una risposta sola in tutta l'area. Sull'indice (project_id, status, last_seen_at).
        @error_groups = paginated(current_time_range.apply(scope, column: :last_seen_at), columns: SORT_COLUMNS)
        # CYRA-883 — an empty list says when the last error matching the other filters came, so the
        # way out widens the range far enough instead of to a fixed 30 days. One query, only if empty.
        @last_error_at = scope.reorder(nil).maximum(:last_seen_at) if @error_groups.empty?
        # CYRA-883 — one trend per row (one query for the page), the Project column hidden when a
        # single project is in view, and "not tracked" said once when no row on the page tracks users.
        @trends = error_trends(@error_groups)
        @single_project = filter_ids(:project_id).one?
        @users_untracked = @error_groups.any? && @error_groups.none?(&:user_context_tracked?)
        # CYRA-381 — quanti gruppi VISIBILI condividono lo stesso messaggio: la riga lo dice, così si
        # contano i problemi e non le righe. Una query aggregata, non una per riga.
        @same_message_counts = visible.error_groups.where(title: @error_groups.map(&:title))
                                                          .group(:title).count
        # L'ambiente dell'ULTIMA occorrenza di ogni gruppo in pagina: la domanda della riga è "questo
        # riguarda gli utenti veri ADESSO?", non "li ha mai toccati". Una query sola per pagina
        # (DISTINCT ON), mai una per riga.
        @last_environments = ::Errors::Event.where(group_id: @error_groups.map(&:id))
                                            .select("DISTINCT ON (group_id) group_id, environment")
                                            .order("group_id, occurred_at DESC")
                                            .to_h { |event| [ event.group_id, event.environment ] }
        # CYRA-821 — chi sfoglia o riordina ha chiesto SOLO l'elenco: da qui in giù c'è il contesto
        # che sta fuori dal frame e che cambiare pagina non tocca. Filtri, periodo e ricerca restano
        # una navigazione intera, così le chip e l'elenco raccontano sempre la stessa fotografia.
        return render_results_frame if results_frame_request?

        load_filter_projects
        @focused_project = @projects.find { |project| project.id.to_s == filter_ids(:project_id).first } if @single_project
        # CYRA-822 — a quale segnale di aggiornamento si iscrive questa pagina: quello dei soli
        # progetti osservati quando il filtro ne seleziona alcuni, altrimenti quello unico
        # dell'organizzazione. Va dopo la tendina: legge da lì i progetti visibili.
        @live_projects = live_stream_projects
        @environments = ::Errors::Event.where(group_id: visible.error_groups.select(:id))
                                       .distinct.pluck(:environment).compact.sort

        # I conteggi descrivono LO STESSO insieme che l'elenco mostra: scope filtrato SENZA il filtro
        # di stato (quello lo scelgono le pill stesse), in una query sola. `group(:status)` torna
        # chiavi STRINGA, non simboli dell'enum. CYRA-383
        @status_counts = counts_scope.group(:status).count.transform_keys(&:to_s)
        @unresolved_count = @status_counts.fetch("unresolved", 0)
        @resolved_count = @status_counts.fetch("resolved", 0)
        @ignored_count = @status_counts.fetch("ignored", 0)
        @counts_total = @status_counts.values.sum
        # La pill accesa: solo quando UNO stato è selezionato — con più stati insieme nessuna delle
        # tre descrive la lista, e accenderne una direbbe una cosa falsa.
        @active_status = status_filter.size == 1 ? status_filter.first : nil
        @saved_views = saved_views_for("error_groups")
        # CYRA-340 — elenco vuoto: distinguere «non è ancora arrivato niente» da «il periodo o i
        # filtri non lasciano passare nulla». Col periodo predefinito il secondo caso è la norma, e
        # dire al posto suo «nessun errore rilevato» sarebbe falso. Una query solo se serve.
        @has_records = records_present?(@error_groups, visible.error_groups)
      end

      def show
        # Il primo livello dei "simili" è un'EURISTICA, non una chiamata AI: stesso messaggio, stesso
        # progetto, punto del codice diverso. Il fingerprint include il frame di origine, quindi lo
        # stesso errore lanciato da quattro punti diventa quattro gruppi, e qui si rimettono insieme
        # senza costo. Il pannello AI resta per dove il messaggio non coincide alla lettera. CYRA-381
        @similar_groups = Errors::Group.where(project_id: @group.project_id, title: @group.title)
                                       .where.not(id: @group.id)
                                       .order(events_count: :desc).limit(5).to_a
        @range = Errors::Group::RANGES.key?(params[:range]) ? params[:range] : Errors::Group::DEFAULT_RANGE
        @chart_anchor = time_anchor || Time.current
        # Il grafico conta LO STESSO insieme che la tabella mostra: ambiente, rilascio e livello
        # valgono anche per lui. Il drill-down from/to resta fuori di proposito — nasce dal grafico
        # stesso, e applicarlo lascerebbe una barra sola, senza nulla da cliccare per tornare
        # indietro. CYRA-562
        @chart_filtered = event_filters_active?
        @buckets = Errors::Group.buckets_for(@group.id, @range, @chart_anchor, events: filtered_events)[@group.id]

        scope = filtered_events.order(occurred_at: :desc)
        # CYRA-46: drill-down dal blocco dell'istogramma (from/to), componibile coi filtri sopra.
        if (window = time_window)
          @bucket_from, @bucket_to = window
          scope = scope.where(occurred_at: @bucket_from...@bucket_to)
        end
        @events = paginated(scope, columns: OCCURRENCE_SORT_COLUMNS, per: ::Monitoring::Constants::OCCURRENCES_PER_PAGE)
        # Quante occorrenze si mostrano: cinque, salvo richiesta esplicita di vederle tutte. La
        # scelta sta nell'indirizzo e non in una classe CSS perché il page-refresh Turbo ri-renderizza
        # server-side (uno stato solo client si perderebbe a ogni arrivo) e le righe non mostrate
        # restano fuori dal DOM. CYRA-400
        @occurrences_expanded = params[:occurrences] == "all"
        @visible_events = @occurrences_expanded ? @events : @events.first(::Monitoring::Constants::OCCURRENCES_COLLAPSED)
        @selected = @latest = @visible_events.first
        load_symbolications
        load_native_reports

        @environments = @group.events.distinct.pluck(:environment).compact.sort
        @releases = @group.events.distinct.pluck(:release).compact.sort
        @device_breakdown = device_breakdown
        @logs_by_trace = related_logs_by_trace
        @logs_count_by_trace = related_logs_count_by_trace
        @replay_session_ids = replay_session_ids_for(@visible_events)
        # CYRA-376 — il riquadro della sessione registrata compariva solo dove una registrazione
        # c'era già: chi non ne aveva non sospettava nemmeno che il legame esistesse. Ora resta e
        # dice «nessuna», e dove la funzione è spenta ma accendibile porta all'interruttore —
        # calcolato una volta qui, non per ogni occorrenza.
        @replay_collecting = @group.project.session_replay_enabled? && @group.project.supports_session_replay?
        @can_activate_replay = !@replay_collecting && @group.project.supports_session_replay? &&
                               can?("projects.edit", scope: @group.project)
        # CYRA-153: candidati per il dropdown di assegnazione — solo se l'attore può assegnare, così
        # una pagina in sola lettura non paga la query sui membri dell'org.
        @can_assign = can?("errors.assign", scope: @group.project)
        @assignees = current_organization.accounts.order(:name) if @can_assign
        # Log collegati manualmente (Logs::Link, CYRA-163), distinti dalla correlazione automatica
        # per trace_id sopra: backlink di sola lettura verso i log agganciati a mano a questo gruppo.
        @linked_log_entries = @group.linked_log_entries.recent.limit(50)
      end

      # Session replay dell'occorrenza (rrweb events uniti, JSON) per il player nella show. rid =
      # replay_session_id dell'occorrenza; risolto SOLO entro il progetto del gruppo visibile (anti-BOLA).
      def replay
        session = Replays::Session.find_by(project_id: @group.project_id, replay_session_id: params[:rid])
        return head :not_found if session.nil? || params[:rid].blank?

        result = Replays::Read.call(session:)
        if result.err?
          render json: { error: { code: result.error.code, message: result.error.message } }, status: result.error.status
        else
          render json: { data: { events: result.value } }
        end
      end

      # Breakdown device del gruppo (solo eventi con contexts.os/app, tipicamente mobile/browser):
      # top 5 combinazioni OS e top 5 versioni app con conteggi. Eventi server-side → hash vuoti.
      def device_breakdown
        {
          os: @group.events.where.not(os_name: nil)
                    .group(:os_name, :os_version).order("count_all DESC").limit(5).count,
          apps: @group.events.where.not(app_version: nil)
                      .group(:app_version).order("count_all DESC").limit(5).count
        }
      end

      # CYRA-192: elimina il gruppo e le sue occorrenze (`dependent: :destroy`). Nessun vincolo di
      # stato: chi ha errors.destroy sa cosa sta cancellando, e imporre «prima risolvilo» non
      # proteggerebbe da nulla. Si torna all'elenco — la pagina appena cancellata non esiste più.
      def destroy
        project = @group.project
        @group.destroy!
        Errors::Broadcast.refresh_list(current_organization, projects: [ project ])
        redirect_to member_monitoring_error_groups_path, notice: t("member.monitoring.delete.done")
      end

      # Cluster "errori simili": gruppi dello stesso progetto con la stessa causa (oltre al fingerprint).
      # Asincrono come triage_ai.
      def similar
        enqueue_ai_request!(kind: "error_similar", args: { group_id: @group.id })
      end

      def promote
        result = Errors::PromoteToTicket.call(
          group: @group, reporter: Current.account, true_actor: Current.true_account
        )
        if result.ok?
          redirect_to member_monitoring_error_group_path(@group),
                      notice: t("member.monitoring.promoted", code: result.value.code)
        else
          redirect_to member_monitoring_error_group_path(@group),
                      alert: t("member.monitoring.promote_failed")
        end
      end

      # CYRA-153: assegna/disassegna l'errore (assignee_id vuoto = disassegna). Il service filtra
      # sull'org (anti-BOLA). Il realtime è un page-refresh della SHOW (refresh_group), non un replace
      # della riga index: l'assegnatario si mostra nell'header della show, non nella riga della lista —
      # un replace lì sarebbe muto e lascerebbe obsolete le show aperte dagli altri.
      def assign
        Errors::Assign.call(group: @group, assignee_id: params[:assignee_id])
        Errors::Broadcast.refresh_group(@group)
        redirect_to member_monitoring_error_group_path(@group), notice: t("member.monitoring.assigned")
      end

      private

      def load_symbolications
        @symbolications = Errors::Symbolication::Read.call(events: @visible_events)
      rescue Artifacts::Rejected
        @symbolications = @visible_events.to_h do |event|
          [ [ event.project_id, event.id, event.created_at ], { "status" => "unresolved", "reason" => "symbolication_response_budget", "frames" => [] } ]
        end
      end

      def load_native_reports
        events = @visible_events.select do |event|
          event.payload["platform"] == "native" || @symbolications.dig([ event.project_id, event.id, event.created_at ], "kind") == "native"
        end
        @native_reports = Errors::Symbolication::Native::ReportRead.call(project: @group.project, events: events)
      rescue Artifacts::Rejected
        @native_reports = {}
        @native_report_budget = true
      end

      # Record di cui cercare la conoscenza vicina (contratto Member::KnowledgeRelatedPanel).
      def knowledge_related_record = @group

      # CYRA-562 — le occorrenze del gruppo come le ha scelte chi guarda: la stessa base per il
      # grafico in cima e per la tabella sotto, così le due non possono più raccontare cose diverse.
      # Senza la finestra del blocco cliccato (vedi #show), che è una selezione dentro questo insieme.
      def filtered_events
        scope = @group.events
        scope = scope.where(environment: filter_ids(:environment)) if filter_ids(:environment).any?
        scope = scope.where(release: filter_ids(:release)) if filter_ids(:release).any?
        scope = scope.where(level: event_level_filter) if event_level_filter.any?
        scope
      end

      # Se un filtro delle occorrenze è acceso: decide se il grafico vuoto può offrire di toglierli
      # (dove filtri non ce ne sono, «azzera i filtri» manderebbe a sbattere sulla stessa pagina).
      def event_filters_active?
        filter_ids(:environment).any? || filter_ids(:release).any? || event_level_filter.any?
      end

      # Quali occorrenze hanno effettivamente un replay registrato: una sola query per l'intera lista
      # (no N+1), restituisce l'insieme dei replay_session_id con una Replays::Session nel progetto.
      def replay_session_ids_for(events)
        ids = events.filter_map(&:replay_session_id).uniq
        return Set.new if ids.empty?

        Replays::Session.where(project_id: @group.project_id, replay_session_id: ids)
                        .pluck(:replay_session_id).to_set
      end

      # I log della stessa richiesta mappati per trace_id, così il pannello segue l'occorrenza
      # selezionata e non la più recente. Una query batch sui trace_id delle occorrenze MOSTRATE. Il
      # cap per occorrenza è A LIVELLO DB con ROW_NUMBER partizionato per trace: un LIMIT globale
      # mescolerebbe i trace, tagliare in memoria caricherebbe un trace rumoroso intero. CYRA-51
      def related_logs_by_trace
        trace_ids = @visible_events.filter_map { |event| event.trace_id.presence }.uniq
        return {} if trace_ids.empty?

        ranked = visible.logs
                 .where(project_id: @group.project_id, trace_id: trace_ids)
                 .select("logs_entries.*, ROW_NUMBER() OVER (PARTITION BY logs_entries.trace_id " \
                         "ORDER BY logs_entries.occurred_at DESC, logs_entries.id DESC) AS occurrence_rank")
        Logs::Entry.from(ranked, :logs_entries)
                   .where("occurrence_rank <= ?", RELATED_LOGS_PER_OCCURRENCE)
                   .order(occurred_at: :desc, id: :desc)
                   .group_by(&:trace_id)
      end

      # Conteggio TOTALE dei log per trace, NON cappato a RELATED_LOGS_PER_OCCURRENCE: è il volume
      # onesto della richiesta, e query separata da #related_logs_by_trace proprio perché quella
      # tronca e non conosce il totale. Una GROUP BY sui trace_id in pagina, servita dall'indice.
      # Scoping visible.logs + project_id del gruppo: nessun leak cross-progetto. CYRA-60
      def related_logs_count_by_trace
        trace_ids = @visible_events.filter_map { |event| event.trace_id.presence }.uniq
        return {} if trace_ids.empty?

        visible.logs
          .where(project_id: @group.project_id, trace_id: trace_ids)
          .group(:trace_id).count
      end

      # CYRA-375 — l'atterraggio predefinito: chi apre l'area senza aver scelto niente vede i NON
      # RISOLTI del sito vero, che è la domanda con cui ci si arriva in emergenza. Basta un parametro
      # qualsiasi dei filtri (anche `status=` vuoto, che è ciò che manda il pannello quando si
      # sceglie "tutti") perché il default si spenga: da lì in poi comanda chi guarda.
      DEFAULT_ENVIRONMENT = "production"

      def environment_filter = filter_ids(:environment)

      # Il filtro CHIESTO è secco: solo i gruppi con almeno un'occorrenza in quell'ambiente.
      # Il default invece non deve nascondere niente di cui non sappiamo l'ambiente: un gruppo le cui
      # occorrenze non lo dichiarano resta in vista, altrimenti l'atterraggio "più utile" diventerebbe
      # un modo per perdere errori veri senza accorgersene.
      def filter_by_environment(scope)
        return scope.where(id: events_in(environment_filter)) if environment_filter.any?
        return scope if filters_touched?

        scope.where(id: events_in([ DEFAULT_ENVIRONMENT ]))
             .or(scope.where.not(id: visible_events.where.not(environment: nil).select(:group_id)))
      end

      def events_in(environments) = visible_events.where(environment: environments).select(:group_id)

      # A group's events live in the group's project: scoping by project keeps the subquery on this
      # tenant's rows instead of every event on the platform (CYRA-893).
      def visible_events = ::Errors::Event.where(project_id: visible.projects.select(:id))

      # CYRA-821 — il frame in cui vivono i risultati: sfogliare e riordinare chiedono solo lui.
      def results_frame_id = "errors-results"

      # CYRA-883 — the range is a filter chip hidden on its default: a toolbar submit (the `ft`
      # marker) without a range asks for the default, it does not restore the remembered one.
      def time_range_declared? = super || params[RememberableFilters::MARKER_PARAM].present?

      TREND_BARS = 24

      # Events per row over the list's range (a custom range falls back to 30 days), folded into at
      # most TREND_BARS bars so the column keeps one width whatever the range.
      def error_trends(groups)
        @trend_range = Errors::Group::RANGES.key?(current_time_range.key) ? current_time_range.key : "30d"
        Errors::Group.buckets_for(groups.map(&:id), @trend_range).transform_values do |buckets|
          counts = buckets.map { |bucket| bucket[:count] }
          counts.each_slice((counts.size / TREND_BARS.to_f).ceil).map(&:sum)
        end
      end

      # Lo scope su cui si contano le pill: gli stessi filtri dell'elenco, meno lo stato — così le
      # tre voci sommano al totale e non si contraddicono mai fra loro.
      def counts_scope
        scope = visible.error_groups
        scope = filter_by_environment(scope)
        # CYRA-383 vale anche per il tempo: i conteggi descrivono LO STESSO insieme dell'elenco,
        # altrimenti le pill direbbero numeri di un periodo che la lista non mostra.
        scope = current_time_range.apply(scope, column: :last_seen_at)
        scope = scope.where(level: level_filter) if level_filter.any?
        scope = scope.where(has_unhandled: true) if unhandled_only_filter?
        scope = scope.where(project_id: filter_ids(:project_id)) if filter_ids(:project_id).any?
        if search_q.present?
          scope = scope.where("errors_groups.title ILIKE :q OR errors_groups.culprit ILIKE :q", q: "%#{search_q}%")
        end
        scope
      end

      def status_filter
        chosen = enum_filter(:status, Errors::Group.statuses.keys)
        return chosen if chosen.any? || filters_touched?

        [ "unresolved" ]
      end

      # Ha scelto qualcosa chi ha toccato uno qualunque dei filtri della pagina: allora nessun default
      # si intromette. Un link vecchio senza parametri atterra sulla vista predefinita — è il cambio
      # dichiarato dal ticket, e riporta chi lo apre su ciò che riguarda gli utenti veri.
      def filters_touched?
        # CYRA-694 — anche il marker della toolbar conta come «toccato»: «Azzera filtri» dichiara
        # l'insieme vuoto, e l'insieme vuoto mostra tutto — non il restringimento di default.
        params.key?(RememberableFilters::MARKER_PARAM) ||
          params.key?(:status) || params.key?(:environment) || params.key?(:level) ||
          params.key?(:project_id) || params.key?(:handled) || params[:q].present?
      end

      def level_filter = enum_filter(:level, Errors::Group.levels.keys)
      def event_level_filter = enum_filter(:level, Errors::Event.levels.keys)

      # Filtro "solo non-gestiti" (CYRA-49, fedele al DoD). has_unhandled=true INCLUDE anche i gruppi
      # misti (hanno almeno un crash) — è il senso onesto di "crash veri". Non c'è il lato opposto:
      # has_unhandled=false NON è "catture volontarie" (comprende anche gli sconosciuti handled=nil, es.
      # capture_message), quindi sarebbe un'etichetta fuorviante.
      def unhandled_only_filter? = filter_ids(:handled).include?("unhandled")
    end
  end
end
