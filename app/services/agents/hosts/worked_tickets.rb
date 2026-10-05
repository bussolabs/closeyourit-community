# frozen_string_literal: true

module Agents
  module Hosts
    # I ticket che un host ha lavorato, dal più recente (CYRA-279). Una riga per LAVORAZIONE, non
    # per tentativo: la domanda è «su cosa ha lavorato», non «quante volte ci è tornato sopra» —
    # quella la racconta la colonna dei passaggi.
    #
    # Ritorna un Pagination::Result come ogni altra lista dell'app, così la vista usa
    # Ui::PaginationComponent senza sapere che sotto c'è un GROUP BY. Il conteggio e la fetta di
    # pagina sono calcolati qui invece di passare da Pagination.call: quel metodo fa `scope.count`,
    # e su una relation con GROUP BY *e* select aggregata Rails avvolge l'intera select list dentro
    # COUNT(...) producendo SQL invalido. Il Result — il contratto che la vista consuma — resta lo
    # stesso, e con esso Pagination::DEFAULT_PER e il tetto MAX_PER.
    #
    # Due query per pagina: una per gli aggregati della sola fetta, una per i workflow (con ticket
    # e progetto) di quella fetta. Zero N+1.
    class WorkedTickets < ApplicationService
      # `workflow` arriva precaricato: la vista non deve interrogare il DB per riga.
      # `workflow_seconds` è nil finché la lavorazione non è arrivata in fondo — nil ≠ zero.
      Row = Data.define(:workflow_id, :workflow, :attempts, :host_seconds, :last_at,
                        :phases, :last_status) do
        def ticket = workflow&.ticket

        def workflow_seconds
          return nil unless workflow&.completed_at

          start = workflow.triage_requested_at || workflow.created_at
          (workflow.completed_at - start).round
        end
      end

      # CYRA-451 — `phase` e `outcome` restringono la lista alle lavorazioni dietro UNA cella della
      # tabella per passaggio: 98 interrotti su 146 erano un numero senza un elenco da aprire.
      # Entrambi sono allowlist (fasi del profilo, categorie di esito): un valore fuori vocabolario
      # viene ignorato invece di svuotare la lista o di finire in una condizione SQL.
      def initialize(host:, range: StatsRange::DEFAULT, page: 1, per: Pagination::DEFAULT_PER,
                     phase: nil, outcome: nil, sort: nil, now: Time.current)
        @host = host
        @sort = sort.to_s
        @window = StatsRange.window(range, now:)
        @page = page
        @per = per.to_i.clamp(1, Pagination::MAX_PER)
        @phase = phase.to_s.presence_in(::Agents::PhaseProfile::PHASES)
        @outcome = outcome.to_s.presence_in(Performance::OUTCOME_GROUPS.keys.map(&:to_s))
      end

      # Filtri effettivamente applicati (dopo l'allowlist): la vista ci costruisce i chip da togliere.
      def self.filters_from(phase:, outcome:)
        { phase: phase.to_s.presence_in(::Agents::PhaseProfile::PHASES),
          outcome: outcome.to_s.presence_in(Performance::OUTCOME_GROUPS.keys.map(&:to_s)) }.compact
      end

      def call
        total = attempts.distinct.count(:workflow_id)
        total_pages = total.zero? ? 1 : (total.to_f / @per).ceil
        page = @page.to_i.clamp(1, total_pages)

        rows = build_rows(page_tuples(page))
        Pagination::Result.new(records: rows, page:, per: @per, total:, total_pages:)
      end

      private

      # Attempt TERMINALI di questo host nella finestra: stesso perimetro di Performance, così i
      # numeri in cima alla pagina descrivono davvero le righe che stanno sotto.
      def attempts
        @attempts ||= begin
          scope = ::Agents::Attempt.where(host_id: @host.id, status: statuses_filter)
          scope = scope.where(started_at: @window) if @window
          scope = scope.where(phase: @phase) if @phase
          scope
        end
      end

      # Il filtro d'esito restringe gli status terminali alla categoria scelta, senza mai uscire da
      # quell'insieme: la lista resta lo stesso perimetro degli aggregati, solo più stretta.
      def statuses_filter
        return ::Agents::Attempt::TERMINAL_STATUSES unless @outcome

        Performance::OUTCOME_GROUPS.fetch(@outcome.to_sym)
      end

      # `last_at` usa COALESCE: un tentativo interrotto senza istante di fine deve comunque poter
      # datare la riga, altrimenti la lavorazione scivola in fondo proprio quando è appena successa.
      # Le fasi viaggiano come CSV e non come array SQL: una stringa non dipende dal type-map
      # dell'adapter, e l'ordine giusto lo dà comunque PhaseProfile in Ruby.
      LAST_TOUCH = "MAX(COALESCE(agents_attempts.finished_at, agents_attempts.started_at))"

      SELECTS = [
        "agents_attempts.workflow_id",
        "COUNT(*)",
        "SUM(EXTRACT(EPOCH FROM (agents_attempts.finished_at - agents_attempts.started_at)))",
        LAST_TOUCH,
        "STRING_AGG(DISTINCT agents_attempts.phase, ',')",
        "(ARRAY_AGG(agents_attempts.status ORDER BY agents_attempts.started_at DESC))[1]"
      ].freeze

      # CYRA-924 — the columns the list sorts on (C9), as SQL over one workflow's attempts. Phases
      # hold several values and do not sort. Only these strings reach the ORDER BY.
      WORKFLOW = "(SELECT %s FROM agents_workflows WHERE agents_workflows.id = agents_attempts.workflow_id)"
      SORT_COLUMNS = {
        "ticket" => "(SELECT ticketing_tickets.number FROM agents_workflows JOIN ticketing_tickets " \
                    "ON ticketing_tickets.id = agents_workflows.ticket_id WHERE agents_workflows.id = agents_attempts.workflow_id)",
        "outcome" => SELECTS.last,
        "host_time" => SELECTS[2],
        "workflow_time" => format(WORKFLOW, "agents_workflows.completed_at - COALESCE(agents_workflows.triage_requested_at, agents_workflows.created_at)"),
        "last" => LAST_TOUCH
      }.freeze

      def ordering
        key = @sort.delete_prefix("-")
        expr = SORT_COLUMNS[key]
        return "#{LAST_TOUCH} DESC" unless expr

        "#{expr} #{@sort.start_with?("-") ? "DESC" : "ASC"} NULLS LAST, #{LAST_TOUCH} DESC"
      end

      def page_tuples(page)
        attempts.group(:workflow_id)
                .order(Arel.sql(ordering))
                .offset((page - 1) * @per).limit(@per)
                .pluck(*SELECTS.map { |sql| Arel.sql(sql) })
      end

      def build_rows(tuples)
        workflows = load_workflows(tuples.map(&:first))
        tuples.map do |workflow_id, attempts_count, host_seconds, last_at, phases_csv, last_status_id|
          Row.new(workflow_id:, workflow: workflows[workflow_id], attempts: attempts_count.to_i,
                  host_seconds: host_seconds&.to_f&.round, last_at:,
                  phases: ordered_phases(phases_csv),
                  last_status: ::Agents::Attempt.statuses.key(last_status_id))
        end
      end

      def load_workflows(ids)
        return {} if ids.empty?

        ::Agents::Workflow.where(id: ids).includes(ticket: :project).index_by(&:id)
      end

      # Le fasi nell'ordine del flusso, non in quello alfabetico dell'aggregazione: una riga che
      # dice "triage → lavorazione" si legge, una che dice "lavorazione, triage" fa fermare.
      def ordered_phases(csv)
        ::Agents::PhaseProfile::PHASES & csv.to_s.split(",")
      end
    end
  end
end
