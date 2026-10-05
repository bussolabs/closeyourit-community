# frozen_string_literal: true

module Member
  module Monitoring
    # Performance monitoring (UI Member): gruppi-metrica con tutti i kind — misure raw (query/metodi lenti)
    # E verdetti aggregati performance_issue (N+1, slow request, slow external HTTP), questi ultimi faceted
    # per `subtype`. Lettura per chiunque veda i progetti (scoping visible.metric_groups, anti-BOLA);
    # promote a ticket gated da metrics.promote. La show correla log↔errori della stessa richiesta via
    # trace_id del campione selezionato (quando presente).
    class MetricGroupsController < Member::BaseController
      permission_not_required "Prestazioni dei progetti visibili: sola lettura, il confine è la visibilità dei " \
                              "progetti.",
                              only: %i[index show]

      # CYRA-737 — la base condivisa delle pagine-elenco dell'area di controllo; da lì arriva anche
      # il periodo (CYRA-340), lo stesso di errori e log, ricordato fra le pagine.
      include Indexable

      # Whitelist ordinamento (contratto Sortable#sorted). avg = espressione aritmetica
      # row-local (stessa formula del valore in riga), cheap; Ticket resta statico.
      # CYRA-339: total_duration = costo complessivo (colonna aggregata mantenuta in scrittura), chiave
      # di sort E ordine di default (vedi #index) — mette in cima ciò che pesa davvero, non la media.
      # CYRA-924 — the samples of one group sort on every column (C9). Query count and cache live in
      # the payload: a value that is not a whole number sorts as missing instead of failing the cast.
      OCCURRENCE_SORT_COLUMNS = {
        "when" => :occurred_at,
        "duration" => :duration_ms,
        "queries" => "CASE WHEN metrics_samples.payload->>'query_count' ~ '^[0-9]+$' " \
                     "THEN (metrics_samples.payload->>'query_count')::bigint END",
        "environment" => "LOWER(metrics_samples.environment)",
        "cached" => "(metrics_samples.payload->>'cached') = 'true'"
      }.freeze

      SORT_COLUMNS = {
        "signature" => "LOWER(metrics_groups.title)",
        "project" => { expr: "LOWER(projects.name)", joins: :project },
        "kind" => :kind,
        "avg" => "(metrics_groups.duration_total_ms / NULLIF(metrics_groups.samples_count, 0))",
        "max" => :duration_max_ms,
        "total_duration" => :duration_total_ms,
        "occurrences" => :samples_count,
        "last_seen" => :last_seen_at
      }.freeze

      # Solo sull'elenco: nel dettaglio `from`/`to` sono il blocco cliccato sull'istogramma, un
      # drill-down locale che non deve diventare il periodo di tutta l'area.
      monitoring_time_range
      # CYRA-694 — i filtri, DOPO il periodo (vedi ErrorGroupsController); `from`/`to` restano suoi.
      remembers_filters :kind, :subtype, :status, :seen, :open, :project_id, :q, :sort, only: :index
      before_action :set_group, only: %i[show promote triage_ai]
      before_action :require_triage_role, only: %i[promote triage_ai]

      def index
        # CYRA-339: default = costo complessivo decrescente (costliest_first), non più recency; se
        # arriva ?sort=... Sortable#sorted lo sovrascrive. Cambia l'ordine dei link senza `sort`.
        scope = shared_filters(visible.metric_groups.includes(:project, :ticket).costliest_first)
        # Categoria e tipo di problema restano FUORI da `shared_filters` di proposito: sono la
        # dimensione che le pill stesse rappresentano (CYRA-815, come lo stato in CYRA-383), e
        # applicarli anche ai conteggi darebbe «Query lente: 0» sopra un elenco di sole query lente.
        scope = scope.where(kind: kind_filter) if kind_filter.any?
        scope = scope.where(subtype: subtype_filter) if subtype_filter.any?
        @metric_groups = paginated(scope, columns: SORT_COLUMNS)
        # CYRA-821 — chi sfoglia o riordina ha chiesto SOLO l'elenco: da qui in giù c'è il contesto
        # che sta fuori dal frame e che cambiare pagina non tocca. Filtri, periodo e ricerca restano
        # una navigazione intera, così le pill e l'elenco raccontano sempre la stessa fotografia.
        return render_results_frame if results_frame_request?

        load_filter_projects
        # CYRA-822 — a quale segnale di aggiornamento si iscrive questa pagina: quello dei soli
        # progetti osservati quando il filtro ne seleziona alcuni, altrimenti quello unico
        # dell'organizzazione. Va dopo la tendina: legge da lì i progetti visibili.
        @live_projects = live_stream_projects

        # CYRA-815 — le pill contano sullo STESSO insieme che l'elenco mostra. Prima solo il totale
        # seguiva i filtri e le altre quattro voci parlavano di tutta la storia dell'organizzazione:
        # si leggeva «Gruppi: 19» accanto a «Query lente: 1.900», con lo stesso aspetto, e la pagina
        # sembrava rotta. `group(:kind).count` torna chiavi STRINGA, non simboli dell'enum.
        counts = counts_scope
        @kind_counts = counts.group(:kind).count.transform_keys(&:to_s)
        @slow_query_count = @kind_counts.fetch("slow_query", 0)
        @slow_method_count = @kind_counts.fetch("slow_method", 0)
        @performance_issue_count = @kind_counts.fetch("performance_issue", 0)
        # Il totale è la SOMMA delle tre categorie: toglie il filtro di categoria e riporta
        # all'insieme intero, esattamente come la pill «Issue» degli errori.
        @counts_total = @kind_counts.values.sum
        # CYRA-339: il riquadro non promuove più la media più alta (distorta da 1-2 casi) ma il tempo
        # totale speso = somma delle durate totali → valore robusto che regge il confronto.
        # CYRA-815 — e quel tempo NON diventa «gli eventi del periodo» solo perché i gruppi sono
        # filtrati: `duration_total_ms` è cumulativo dalla nascita del gruppo, quindi i filtri
        # scelgono QUALI gruppi sommare e il numero resta il loro costo da sempre. Non è
        # nascondibile: sta scritto nell'etichetta della pill. A insieme vuoto è nil → «—», perché
        # zero gruppi non hanno consumato zero: non hanno consumato niente di cui si sappia.
        @total_duration = @counts_total.zero? ? nil : counts.sum(:duration_total_ms)
        # La pill accesa: solo quando UNA categoria è selezionata — con più categorie insieme
        # nessuna delle tre descrive la lista, e accenderne una direbbe una cosa falsa.
        @active_kind = kind_filter.size == 1 ? kind_filter.first : nil
        # «Gruppi» è acceso solo quando l'elenco è DAVVERO l'insieme intero, e non basta che nessuna
        # categoria sia sola: con due categorie insieme, o col solo tipo di problema, `@active_kind`
        # è nil ma la lista è ristretta — accendere il totale prometterebbe un elenco più largo di
        # quello che si sta guardando. Sono due domande diverse e vogliono due valori diversi.
        @kinds_unfiltered = kind_filter.empty? && subtype_filter.empty?
        @saved_views = saved_views_for("metric_groups")
        # CYRA-355 — viste già pronte per chi non ne ha nessuna: la funzione che serve a domare
        # duemila gruppi non può chiedere di immaginarsi da zero quali siano le domande giuste.
        @saved_view_presets = @saved_views.any? ? [] : metric_view_presets
        # CYRA-340 — elenco vuoto: «non è ancora arrivato niente» o «il periodo non lascia passare
        # nulla»? Sono due frasi diverse. Una query solo quando la lista è vuota.
        @has_records = records_present?(@metric_groups, visible.metric_groups)
      end

      def show
        @range = Metrics::Group::RANGES.key?(params[:range]) ? params[:range] : Metrics::Group::DEFAULT_RANGE
        @chart_anchor = time_anchor || Time.current
        # CYRA-341: il colore non è più un giudizio segreto uguale per tutti — le soglie sono del progetto.
        @thresholds = ::Metrics::Thresholds.for(@group.project)
        @buckets = Metrics::Group.buckets_for(@group.id, @range, @chart_anchor, thresholds: @thresholds)[@group.id]
        # CYRA-341: «sta peggiorando?» — la durata nel tempo (p50/p95 per blocco) e il confronto con
        # il periodo precedente della stessa lunghezza. Stessi blocchi dell'istogramma occorrenze.
        @duration_buckets = Metrics::Group.duration_buckets_for(@group.id, @range, @chart_anchor, thresholds: @thresholds)
        @trend = @group.duration_trend(@range, @chart_anchor)
        scope = @group.samples.order(occurred_at: :desc)
        # CYRA-46: drill-down dal blocco dell'istogramma (from/to del blocco cliccato).
        if (window = time_window)
          @bucket_from, @bucket_to = window
          scope = scope.where(occurred_at: @bucket_from...@bucket_to)
        end
        @occurrences = paginated(scope, columns: OCCURRENCE_SORT_COLUMNS, per: ::Monitoring::Constants::OCCURRENCES_PER_PAGE)
        # CYRA-352 — perché i due numeri non coincidono: il contatore del gruppo conta TUTTE le volte
        # che è successo e non cala mai; le righe qui sotto sono i campioni ancora conservati, che
        # Metrics::PruneSamplesJob pota oltre la retention del progetto. Non c'è nessun
        # campionamento in ingresso (l'ingest scrive sempre la riga, al più senza il corpo): la
        # differenza è potatura, e la nota lo dice.
        @samples_retention_days = ::Metrics::Retention.for(@group.project)
        @selected = @occurrences.first
        # CYRA-146: percentili p50/p95/p99 dai campioni conservati (una query, solo questo gruppo).
        @percentiles = @group.duration_percentiles
        @related_logs = related_logs
        @related_errors = related_errors
      end

      def promote
        result = Metrics::PromoteToTicket.call(
          group: @group, reporter: Current.account, true_actor: Current.true_account
        )
        if result.ok?
          redirect_to member_monitoring_metric_group_path(@group),
                      notice: t("member.metrics.promoted", code: result.value.code)
        else
          redirect_to member_monitoring_metric_group_path(@group),
                      alert: t("member.metrics.promote_failed")
        end
      end

      # CYRA-45: triage bulk dalla lista, speculare agli errori. Query/metodi lenti di rumore da un
      # deploy → resolve/ignore in massa. Anti-BOLA a due strati: id VISIBILI (visible.metric_groups)
      # + solo quelli su cui ho metrics.promote per il loro progetto (unica chiave di gestione metriche).
      # Broadcast batch: un solo page-refresh org dopo il commit.
      def bulk_triage
        permitted_ids = triageable_metric_group_ids(params[:ids])
        result = Metrics::BulkTriage.call(
          scope: visible.metric_groups, ids: permitted_ids, action: params[:bulk_action]
        )
        return redirect_to member_monitoring_metric_groups_path, alert: t("member.metrics.bulk.invalid") if result.err?

        # Il bulk può attraversare più progetti: si dichiarano tutti quelli toccati, o le liste
        # filtrate su uno di essi non si accorgerebbero del triage (CYRA-822).
        Metrics::Broadcast.refresh_list(current_organization, projects: result.value.map(&:project)) if result.value.any?
        redirect_to member_monitoring_metric_groups_path,
                    notice: t("member.metrics.bulk.done", count: result.value.size)
      end

      # Triage AI on-demand (draft non persistito, sincrono): l'AI propone categoria/severità/fix e se
      # vale un ticket; l'umano promuove col pulsante nativo. Vedi Metrics::TriageWithAi.
      def triage_ai
        enqueue_ai_request!(kind: "metric_triage", args: { group_id: @group.id })
      end

      private

      def require_triage_role
        require_permission!("metrics.promote", scope: @group.project)
      end

      # Anti-BOLA + scoping: gruppo non visibile (altra org o progetto non assegnato) → RecordNotFound.
      def set_group
        @group = visible.metric_groups.find(params[:id])
      end

      # Id dei gruppi-metrica selezionati su cui l'attore può fare triage: visibili E con metrics.promote
      # sul rispettivo progetto. Id non visibile/senza permesso → scartato (il bulk applica il possibile).
      def triageable_metric_group_ids(ids)
        visible.metric_groups.where(id: Array(ids).reject(&:blank?)).includes(:project)
                                     .select { |group| can?("metrics.promote", scope: group.project) }
                                     .map(&:id)
      end

      # CYRA-815 — i filtri che elenco e pill condividono, scritti UNA volta sola: stato del triage,
      # progetto, «solo non promossi», periodo e ricerca. Due copie della stessa catena divergono, e
      # la divergenza è esattamente il guasto che questa correzione chiude.
      def shared_filters(scope)
        scope = scope.where(status: status_filter) if status_filter.any? # CYRA-45: filtro stato triage
        scope = filter_by_project(scope)
        # open: solo i gruppi non ancora promossi a ticket (ticket_id nil = lavoro aperto). Deep-link dal
        # KPI "Perf issue" della dashboard, che conta i performance_issue non promossi → card e lista combaciano.
        scope = scope.where(ticket_id: nil) if params[:open].present?
        # CYRA-355 → CYRA-340 — «cosa si è mosso ultimamente» è la prima domanda davanti a duemila
        # gruppi, e ora si chiede con lo stesso selettore di errori e log invece che con un filtro
        # solo di questa pagina. Sull'indice (project_id, kind, last_seen_at).
        scope = current_time_range.apply(scope, column: :last_seen_at)
        filter_by_search(scope, "metrics_groups.title")
      end

      # Lo scope su cui si contano le pill: gli stessi filtri dell'elenco, meno categoria e tipo di
      # problema — quelli li scelgono le pill stesse, così le tre voci sommano al totale.
      def counts_scope = shared_filters(visible.metric_groups)

      # CYRA-821 — il frame in cui vivono i risultati: sfogliare e riordinare chiedono solo lui.
      def results_frame_id = "metrics-results"

      def kind_filter = enum_filter(:kind, Metrics::Group.kinds.keys)
      def subtype_filter = enum_filter(:subtype, Metrics::Group::PERFORMANCE_SUBTYPES)
      def status_filter = enum_filter(:status, Metrics::Group.statuses.keys)

      # Le tre domande che si fanno tutti davanti a duemila gruppi: cosa si è mosso di recente, cosa
      # costa di più, cosa non è ancora stato preso in carico. Sono link con dei filtri, non righe
      # salvate: nessuno si ritrova in casa roba che non ha creato.
      #
      # CYRA-561 — ogni scorciatoia deve spostare qualcosa, e nella direzione che il suo nome promette:
      #   · «recente» chiedeva `range=24h`, che è già il periodo predefinito (Monitoring::TimeRange::DEFAULT):
      #     premerla lasciava la pagina identica, e una scorciatoia che non sposta niente sembra rotta.
      #     Ora è un ORDINE — l'ultima volta vista, dalla più recente — che è la domanda per cui era nata
      #     e l'unico taglio davvero diverso dal predefinito (costo complessivo decrescente).
      #   · «costano di più» chiedeva `total_duration` senza trattino: per Sortable (stile JSON:API) è
      #     CRESCENTE, e in cima finiva la query eseguita una volta sola da un decimo di secondo — cioè
      #     l'esatto contrario del nome. Il trattino la fa decrescente, come l'intestazione di colonna.
      def metric_view_presets
        [
          { key: "recent", name: t("shared.saved_views.preset_metrics_recent"),
            filters: { "sort" => "-last_seen" } },
          { key: "costliest", name: t("shared.saved_views.preset_metrics_costliest"),
            filters: { "sort" => "-total_duration" } },
          { key: "untriaged", name: t("shared.saved_views.preset_metrics_untriaged"),
            filters: { "open" => "1", "status" => [ "unresolved" ] } }
        ]
      end

      # Correlazione automatica: log della stessa richiesta (stesso trace_id + progetto).
      def related_logs
        return Logs::Entry.none if @selected&.trace_id.blank?

        visible.logs.where(project_id: @group.project_id, trace_id: @selected.trace_id).recent.limit(50)
      end

      # Errori della stessa richiesta: trace_id indicizzato su errors_events (B1). Order esplicito
      # occurred_at desc + tie-breaker id desc (CYRA-53): senza, i (fino a 50) errori correlati
      # cambierebbero ordine ad ogni refresh e il cap prenderebbe un sottoinsieme indeterminato. Il
      # tie-breaker id rende l'ordine TOTALE e stabile anche a parità di occurred_at (burst con lo
      # stesso timestamp), così il limit seleziona sempre lo stesso sottoinsieme.
      def related_errors
        return Errors::Event.none if @selected&.trace_id.blank?

        # :group precaricato (CYRA-747): ogni riga porta il titolo del gruppo e il link alla sua
        # scheda, quindi senza preload sono fino a cinquanta query per una sola pagina.
        Errors::Event.where(project_id: @group.project_id, trace_id: @selected.trace_id)
                     .includes(:group)
                     .order(occurred_at: :desc, id: :desc).limit(50)
      end
    end
  end
end
