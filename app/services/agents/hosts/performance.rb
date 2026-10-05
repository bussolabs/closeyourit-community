# frozen_string_literal: true

module Agents
  module Hosts
    # Rendimento storico di UN host (CYRA-279): quanti ticket ha lavorato, quanto è durato ogni
    # passaggio, quanto ci mette in media, quanta parte del suo lavoro viene respinta.
    #
    # La sorgente sono gli attempt TERMINALI: sono audit immutabile (Agents::Attempt#ensure_mutable),
    # non vengono mai potati e portano già fase, host, istanti e verdetto. Un attempt ancora aperto
    # NON è un esito e resta fuori da ogni numero — contarlo farebbe scendere le percentuali proprio
    # mentre l'host sta lavorando.
    #
    # Sola lettura → value object, non un Result. Tutte le aggregazioni stanno in SQL: caricare gli
    # attempt in Ruby renderebbe la pagina proporzionale alla storia dell'host invece che costante.
    class Performance < ApplicationService
      # Gli otto status dell'enum ridotti alle quattro categorie che una persona sa leggere. Le
      # quattro sono una PARTIZIONE dei terminali: sommano sempre al totale, quindi le percentuali
      # fanno cento e nessun esito sparisce in un "altro" invisibile.
      #   bocciato ≠ fallito: il primo è un giudizio sul lavoro, il secondo un guasto tecnico.
      #   interrotto non è nessuno dei due: è finita senza consegnare, e non va imputata alla qualità.
      OUTCOME_GROUPS = {
        approved: %w[approved],
        rejected: %w[rejected review_failed],
        failed: %w[failed],
        interrupted: %w[stale cancelled]
      }.freeze

      # Durata di un tentativo in secondi. NULL quando manca l'istante di fine (host morto a metà):
      # AVG e percentile_cont saltano i NULL da soli, quindi un tentativo mai concluso conta nei
      # conteggi ma non falsa i tempi.
      DURATION = "EXTRACT(EPOCH FROM (agents_attempts.finished_at - agents_attempts.started_at))"

      # Tempo di lavorazione del ticket: dalla richiesta di triage alla chiusura. `triage_requested_at`
      # è nullable sui workflow nati prima della coda, quindi il fallback è la nascita del workflow.
      WORKFLOW_DURATION = <<~SQL.squish
        EXTRACT(EPOCH FROM (agents_workflows.completed_at
          - COALESCE(agents_workflows.triage_requested_at, agents_workflows.created_at)))
      SQL

      Outcomes = Data.define(:approved, :rejected, :failed, :interrupted, :total) do
        def approved_pct = percent(approved)
        def rejected_pct = percent(rejected)
        def failed_pct = percent(failed)
        def interrupted_pct = percent(interrupted)

        private

        # nil (non 0) su denominatore vuoto: "nessun dato" e "zero per cento" sono cose diverse e
        # la vista deve poterle rendere diverse.
        def percent(value) = total.zero? ? nil : ((value * 100.0) / total).round(1)
      end

      PhaseRow = Data.define(:phase, :attempts, :approved, :rejected, :failed, :interrupted,
                             :avg_seconds, :median_seconds) do
        # Falso = fase mai eseguita da questo host: la riga resta in tabella, ma spenta.
        def any? = attempts.positive?
      end

      # Costo del periodo (CYRA-451). La sorgente è la stima dichiarata alla partenza
      # (Agents::LimitReservation#estimated_cost): è l'unico costo che il sistema attribuisce a un
      # host, ed è una STIMA — la vista deve dirlo. `untracked` sono le partenze concesse senza costo
      # (host vecchi, o runtime senza tetto di spesa): dichiararle è il modo di non spacciare un
      # totale parziale per completo.
      Cost = Data.define(:total, :tracked, :untracked) do
        def any? = tracked.positive?
        def partial? = any? && untracked.positive?
        def starts = tracked + untracked
      end

      Report = Data.define(:range, :tickets_count, :attempts_count, :outcomes, :cost,
                           :plans_total, :plans_sent_back,
                           :host_seconds_avg, :host_seconds_median,
                           :workflow_seconds_avg, :workflow_seconds_median, :workflow_tickets_count,
                           :by_phase) do
        # Falso = l'host non ha ancora concluso niente: la vista mostra un messaggio, non una
        # griglia di zeri che sembrerebbe un rendimento pessimo invece che assenza di storia.
        def any? = attempts_count.positive?

        # CYRA-499 — «è misurabile?», la domanda che decide se il riquadro esiste. Un tempo non
        # calcolabile mostrava un trattino su ogni periodo e per ogni macchina: si legge come «il
        # sistema non sta misurando», e intanto l'altro tempo passa per il tempo totale.
        #   host_time: nil quando nessun tentativo ha un istante di fine (interrotti a metà).
        #   workflow_time: nil finché nessuna lavorazione toccata dall'host è arrivata alla chiusura.
        def host_time? = !host_seconds_avg.nil?
        def workflow_time? = !workflow_seconds_avg.nil?

        def plans_sent_back_pct
          return nil if plans_total.zero?

          ((plans_sent_back * 100.0) / plans_total).round(1)
        end
      end

      # `previous: true` sposta il perimetro alla finestra precedente della stessa ampiezza: serve a
      # dire se un numero sta migliorando o peggiorando. Su `all` non esiste un prima e il chiamante
      # non deve nemmeno chiedere il confronto (StatsRange.previous_window torna nil).
      def initialize(host:, range: StatsRange::DEFAULT, now: Time.current, previous: false)
        @host = host
        @range = StatsRange.normalize(range)
        @window = previous ? StatsRange.previous_window(@range, now:) : StatsRange.window(@range, now:)
        @previous = previous
      end

      def call
        rows = phase_rows
        Report.new(
          range: @range,
          tickets_count: attempts.distinct.count(:workflow_id),
          attempts_count: rows.sum(&:attempts),
          outcomes: outcomes_from(rows),
          cost: cost_report,
          plans_total: plans.count,
          plans_sent_back: plans.where.not(change_request: [ nil, "" ]).count,
          host_seconds_avg: host_seconds.first,
          host_seconds_median: host_seconds.last,
          workflow_seconds_avg: workflow_seconds[0],
          workflow_seconds_median: workflow_seconds[1],
          workflow_tickets_count: workflow_seconds[2],
          by_phase: rows
        )
      end

      private

      # Il perimetro di TUTTO: attempt terminali di questo host nella finestra scelta.
      def attempts
        @attempts ||= begin
          scope = ::Agents::Attempt.where(host_id: @host.id, status: ::Agents::Attempt::TERMINAL_STATUSES)
          scope = scope.where(started_at: @window) if @window
          # Finestra precedente inesistente (range `all`): nessun perimetro, non "tutto" — senza
          # questo, il confronto mostrerebbe la storia intera come se fosse il periodo prima.
          scope = scope.none if @previous && @window.nil?
          scope
        end
      end

      # Costo del periodo: somma delle stime sulle partenze CONCESSE a questo host nella finestra.
      # Le negate non hanno consumato niente. La finestra è sulla decisione (created_at), che è
      # l'istante in cui la partenza è stata autorizzata.
      def cost_report
        scope = ::Agents::LimitReservation.where(host_id: @host.id, outcome: "granted")
        scope = scope.where(created_at: @window) if @window
        scope = scope.none if @previous && @window.nil?
        # `pick` su una relation vuotata da .none torna nil, non una terna di zeri.
        total, tracked, starts = scope.pick(Arel.sql("COALESCE(SUM(estimated_cost), 0)"),
                                            Arel.sql("COUNT(estimated_cost)"),
                                            Arel.sql("COUNT(*)")) || [ 0, 0, 0 ]
        Cost.new(total: BigDecimal(total.to_s), tracked: tracked.to_i, untracked: starts.to_i - tracked.to_i)
      end

      # Una riga per fase, in UNA query: conteggi per categoria via FILTER + media e mediana.
      # Le fasi mai eseguite non tornano dal GROUP BY e vengono riempite a zero qui: sapere che
      # l'host non ha mai fatto `closer_production` è informazione, non una riga da nascondere.
      def phase_rows
        found = aggregated_phases.index_by(&:phase)
        ::Agents::PhaseProfile::PHASES.map { |phase| found[phase] || empty_phase_row(phase) }
      end

      def aggregated_phases
        attempts.group(:phase).pluck(*phase_selects).map do |phase, count, approved, rejected, failed, interrupted, avg, median|
          PhaseRow.new(phase:, attempts: count, approved:, rejected:, failed:, interrupted:,
                       avg_seconds: avg&.to_f&.round, median_seconds: median&.to_f&.round)
        end
      end

      # Gli id degli status arrivano dall'enum del model, non da input utente: interpolarli è sicuro
      # e tiene la SQL leggibile quanto la mappa che la genera.
      def phase_selects
        filters = OUTCOME_GROUPS.map do |_key, names|
          ids = ::Agents::Attempt.statuses.values_at(*names).join(", ")
          "COUNT(*) FILTER (WHERE agents_attempts.status IN (#{ids}))"
        end
        [ "agents_attempts.phase", "COUNT(*)", *filters,
          "AVG(#{DURATION})", "percentile_cont(0.5) WITHIN GROUP (ORDER BY #{DURATION})" ].map { |sql| Arel.sql(sql) }
      end

      def empty_phase_row(phase)
        PhaseRow.new(phase:, attempts: 0, approved: 0, rejected: 0, failed: 0, interrupted: 0,
                     avg_seconds: nil, median_seconds: nil)
      end

      def outcomes_from(rows)
        Outcomes.new(approved: rows.sum(&:approved), rejected: rows.sum(&:rejected),
                     failed: rows.sum(&:failed), interrupted: rows.sum(&:interrupted),
                     total: rows.sum(&:attempts))
      end

      # Tempo dell'host per TICKET: prima si somma per lavorazione, poi si fa media e mediana di
      # quelle somme. Mediarle sui singoli tentativi risponderebbe a un'altra domanda ("quanto dura
      # un passaggio"), che è già la tabella per fase.
      def host_seconds
        @host_seconds ||= begin
          per_ticket = attempts.group(:workflow_id).select(Arel.sql("SUM(#{DURATION}) AS total"))
          ::Agents::Attempt.unscoped.from(per_ticket, :t)
                           .pick(Arel.sql("AVG(t.total)"), Arel.sql("percentile_cont(0.5) WITHIN GROUP (ORDER BY t.total)"))
                           .map { |value| value&.to_f&.round }
        end
      end

      # Tempo end-to-end delle lavorazioni COMPLETATE che l'host ha toccato. Le lavorazioni ancora
      # aperte restano fuori: includerle con "adesso" come fine farebbe crescere il numero da solo
      # ogni volta che si ricarica la pagina.
      #
      # CYRA-499 — il terzo valore è QUANTE lavorazioni chiuse ci stanno dietro, e la pagina lo
      # scrive: finché i closer non portano un ticket fino in fondo il conteggio resta zero, ed è
      # quello a dire alla vista di non mostrare affatto la misura. Media e mediana da sole non
      # distinguono «mai misurato» da «misurato su due ticket su centosedici».
      def workflow_seconds
        @workflow_seconds ||= begin
          avg, median, count = ::Agents::Workflow
                               .where(id: attempts.select(:workflow_id)).where.not(completed_at: nil)
                               .pick(Arel.sql("AVG(#{WORKFLOW_DURATION})"),
                                     Arel.sql("percentile_cont(0.5) WITHIN GROUP (ORDER BY #{WORKFLOW_DURATION})"),
                                     Arel.sql("COUNT(#{WORKFLOW_DURATION})"))
          [ avg&.to_f&.round, median&.to_f&.round, count.to_i ]
        end
      end

      # Piani prodotti dai tentativi dell'host. `change_request` valorizzato = una persona lo ha
      # rimandato indietro invece di approvarlo.
      def plans
        @plans ||= ::Agents::Plan.where(attempt_id: attempts.select(:id))
      end
    end
  end
end
