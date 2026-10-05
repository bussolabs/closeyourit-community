# frozen_string_literal: true

module Agents
  module Hosts
    # Le stesse misure del rendimento, per PIÙ host sullo stesso periodo (CYRA-451). Esiste perché
    # «di chi mi fido di più» è una domanda di confronto, e leggerla saltando fra due schede
    # costringeva a ricordare i numeri a memoria.
    #
    # Non è un ciclo di Performance: quello farebbe cinque query per host e la pagina crescerebbe
    # con la flotta (il guard N+1 lo conta, giustamente). Qui le aggregazioni sono raggruppate per
    # host_id — quattro query in tutto, quante che siano le macchine confrontate.
    class Comparison < ApplicationService
      Row = Data.define(:host_id, :tickets_count, :attempts_count, :rejected, :interrupted,
                        :host_seconds_median, :workflow_seconds_median, :cost) do
        def any? = attempts_count.positive?
        def rejected_pct = percent(rejected)
        def interrupted_pct = percent(interrupted)

        private

        # nil, non 0: "non misurato" e "zero per cento" sono cose diverse anche qui.
        def percent(value) = attempts_count.zero? ? nil : ((value * 100.0) / attempts_count).round(1)
      end

      def initialize(hosts:, range: StatsRange::DEFAULT, now: Time.current)
        @hosts = Array(hosts)
        @range = StatsRange.normalize(range)
        @window = StatsRange.window(@range, now:)
      end

      def call
        return {} if @hosts.empty?

        counts = counts_by_host
        host_medians = host_seconds_by_host
        workflow_medians = workflow_seconds_by_host
        costs = costs_by_host

        @hosts.to_h do |host|
          tickets, attempts, rejected, interrupted = counts.fetch(host.id, [ 0, 0, 0, 0 ])
          [ host.id, Row.new(host_id: host.id, tickets_count: tickets, attempts_count: attempts,
                             rejected:, interrupted:,
                             host_seconds_median: host_medians[host.id],
                             workflow_seconds_median: workflow_medians[host.id],
                             cost: costs.fetch(host.id, Performance::Cost.new(total: BigDecimal(0), tracked: 0, untracked: 0))) ]
        end
      end

      private

      def host_ids = @hosts.map(&:id)

      # Stesso perimetro di Performance: attempt TERMINALI nella finestra. Un tentativo ancora
      # aperto non è un esito e non deve far scendere le percentuali mentre l'host lavora.
      def attempts
        @attempts ||= begin
          scope = ::Agents::Attempt.where(host_id: host_ids, status: ::Agents::Attempt::TERMINAL_STATUSES)
          @window ? scope.where(started_at: @window) : scope
        end
      end

      def counts_by_host
        rows = attempts.group(:host_id).pluck(
          :host_id,
          Arel.sql("COUNT(DISTINCT agents_attempts.workflow_id)"),
          Arel.sql("COUNT(*)"),
          Arel.sql(outcome_filter(:rejected)),
          Arel.sql(outcome_filter(:interrupted))
        )
        rows.to_h { |host_id, tickets, total, rejected, interrupted| [ host_id, [ tickets, total, rejected, interrupted ] ] }
      end

      # Gli id degli status vengono dall'enum del model, mai da input: passano comunque dai bind di
      # sanitize_sql_array, così la lista resta una lista di interi anche a occhio dell'analisi statica.
      def outcome_filter(group)
        ids = ::Agents::Attempt.statuses.values_at(*Performance::OUTCOME_GROUPS.fetch(group))
        ::Agents::Attempt.sanitize_sql_array([ "COUNT(*) FILTER (WHERE agents_attempts.status IN (?))", ids ])
      end

      # Mediana del tempo speso PER TICKET: prima si somma per lavorazione, poi la mediana di quelle
      # somme — la stessa domanda a cui risponde la scheda del singolo host.
      def host_seconds_by_host
        per_ticket = attempts.group(:host_id, :workflow_id)
                             .select(Arel.sql("agents_attempts.host_id AS host_id, SUM(#{Performance::DURATION}) AS total"))
        ::Agents::Attempt.unscoped.from(per_ticket, :t).group("t.host_id")
                         .pluck(Arel.sql("t.host_id"), Arel.sql("percentile_cont(0.5) WITHIN GROUP (ORDER BY t.total)"))
                         .to_h { |host_id, median| [ host_id, median&.to_f&.round ] }
      end

      # Tempo end-to-end delle lavorazioni COMPLETATE che l'host ha toccato. DISTINCT sulla coppia
      # host+workflow: un host che è tornato tre volte sullo stesso ticket non pesa tre volte.
      def workflow_seconds_by_host
        rows = attempts.joins("INNER JOIN agents_workflows ON agents_workflows.id = agents_attempts.workflow_id")
                       .where.not(agents_workflows: { completed_at: nil })
                       .distinct
                       .pluck(:host_id, Arel.sql("agents_attempts.workflow_id"), Arel.sql(Performance::WORKFLOW_DURATION))
        rows.group_by(&:first).transform_values do |group|
          durations = group.filter_map { |_host_id, _workflow_id, seconds| seconds&.to_f }.sort
          next nil if durations.empty?

          middle = durations.size / 2
          median = durations.size.odd? ? durations[middle] : (durations[middle - 1] + durations[middle]) / 2.0
          median.round
        end
      end

      # Costo stimato del periodo per host, con quante partenze non lo tracciano: un totale parziale
      # spacciato per completo è il rischio dichiarato nel ticket.
      def costs_by_host
        scope = ::Agents::LimitReservation.where(host_id: host_ids, outcome: "granted")
        scope = scope.where(created_at: @window) if @window
        scope.group(:host_id).pluck(:host_id,
                                    Arel.sql("COALESCE(SUM(estimated_cost), 0)"),
                                    Arel.sql("COUNT(estimated_cost)"),
                                    Arel.sql("COUNT(*)"))
             .to_h do |host_id, total, tracked, starts|
          [ host_id, Performance::Cost.new(total: BigDecimal(total.to_s), tracked: tracked.to_i,
                                           untracked: starts.to_i - tracked.to_i) ]
        end
      end
    end
  end
end
