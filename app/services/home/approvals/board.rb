# frozen_string_literal: true

module Home
  module Approvals
    # CYRA-592 — la plancia: una riga per lavorazione e una colonna per ciascuna delle cinque fasi.
    #
    # La coda mostrava una cosa alla volta in tre colonne strette. Con centodieci decisioni ferme su
    # diciassette progetti la domanda non è più «cosa decido adesso» ma «dove si accumula il lavoro»:
    # una riga si legge da sinistra a destra (dove è arrivata) e una colonna dall'alto in basso (dove
    # si fermano tutte). Le due letture funzionano solo se le colonne ci sono SEMPRE tutte, anche le
    # future: una riga con meno celle sposta le altre di posto e la lettura verticale salta.
    #
    # NON è una seconda coda. Le righe, i loro gate e i loro conteggi restano di `Queue`, che questo
    # service riceve già fatta: qui si aggiunge solo ciò che una tabella ha in più di una pila — la
    # matrice delle fasi, il raggruppamento per progetto, la paginazione. Chi decide chi vede cosa
    # resta un posto solo.
    #
    # Sola lettura → ritorna un value object, non un Result.
    #
    #   Home::Approvals::Board.call(batch: queue_batch, page: 1, per: 25) → Plan
    class Board < ApplicationService
      # CYRA-619 — i SEI passaggi del modello, non le cinque fasi interne della macchina.
      #
      # Prima le colonne erano `triage`, `planner`, `autopilot`, `closer_staging`, `closer_production`:
      # parole che nel resto del prodotto non compaiono, e diverse da quelle con cui la riga — due
      # colonne più in là — dice a che punto è. La stessa lavorazione risultava chiamata in due modi
      # sulla stessa riga, e chi guardava doveva tenere a mente una traduzione che nessuno ha scritto.
      PHASES = ::Agents::Workflows::PhaseResolver::STEPS

      # CYRA-899 — groups follow the order of the state filter, so the board and the menu agree.
      STATE_ORDER = Queue::STATES.each_with_index.to_h.freeze

      # Una cella della matrice, uno dei sei passaggi. `state`: done (fatto) · current (è qui che si
      # trova) · failed (si è fermata qui) · pending (non ancora raggiunto).
      #
      # CYRA-619 — `openable` al posto di `attempt_id`: premendo si apre il PASSAGGIO dentro il
      # ticket, non il referto di un singolo tentativo della macchina. Quello è un oggetto interno, a
      # volte l'ultimo di diciannove, e non dice a che punto è il lavoro.
      Cell = Data.define(:phase, :state, :openable) do
        def open? = openable
        def current? = state == "current"
        def failed? = state == "failed"
        def done? = state == "done"
      end

      # Una riga della plancia: la voce di coda così com'è (titolo, azioni, idoneità al blocco — tutto
      # già gated) più ciò che serve a leggerla in orizzontale.
      Row = Data.define(:item, :cells, :ticket_id) do
        def key = item.key
        def state = item.state
        def project = item.project
        # Da quando aspetta: la STESSA ancora d'età con cui la coda ordina, così la colonna «Attesa»
        # e l'ordine delle righe non possono raccontare due storie.
        def since = item.sort_at
        # Ho già chiesto precisazioni e nessuno ha risposto: la palla è a qualcun altro.
        def waiting_reply? = item.waiting_since.present?
        # CYRA-899 — the step the row sits on: the "you are here" cell, or the red one when stopped.
        # A review with no workflow behind it (a person's work) still waits on the review step.
        def step = cells.find { |cell| cell.current? || cell.failed? }&.phase || ("to_review" if state == "review")
        def stuck? = cells.any?(&:failed?)
      end

      # CYRA-899 — one kind of decision (the row state) and its rows ON THE OPEN PAGE: the header
      # count is what is being looked at, not a total the page does not show.
      Group = Data.define(:state, :rows) do
        def size = rows.size
        def key = state
      end

      # `page` = Pagination::Result delle righe (la vista usa Ui::PaginationComponent senza sapere che
      # sotto c'è una lista in memoria); `groups` = le righe della pagina raccolte per progetto;
      # `total` = quante righe ha la plancia intera.
      # CYRA-899 — `phase_counts` = { step => rows sitting on it }, counted BEFORE the phase filter so
      # the counters keep saying where the work piles up; `phase` = the step filter, validated, or nil.
      Plan = Data.define(:page, :groups, :total, :phase_counts, :phase) do
        def any? = total.positive?
      end

      # CYRA-998 — whitelisted sort keys, applied inside each group: "key" ascending, "-key" descending.
      SORTS = {
        "version" => ->(row) { row.item.plan_version },
        # Longer wait = older start: the value grows as the start goes back in time.
        "wait" => ->(row) { row.since && -row.since.to_f }
      }.freeze

      def initialize(batch:, page: 1, per: Pagination::DEFAULT_PER, now: Time.current, phase: nil, sort: nil)
        @batch = batch
        raw = sort.to_s
        @sort_key = raw.delete_prefix("-").presence_in(SORTS.keys)
        @sort_desc = raw.start_with?("-")
        @page = page
        @per = per
        @now = now
        @phase = phase.to_s.presence_in(PHASES)
      end

      def call
        all_rows = build_rows(@batch.items)
        rows = @phase ? all_rows.select { |row| row.step == @phase } : all_rows
        page = Pagination.from_array(rows, page: @page, per: @per)

        Plan.new(page: page, groups: group(page.records), total: rows.size,
                 phase_counts: phase_counts(all_rows), phase: @phase)
      end

      private

      def build_rows(items)
        workflows = workflows_by_key(items)
        ids = workflows.values.map(&:id).uniq
        failed = ::Agents::Workflows::PhaseResolver.failed_phases_by_workflow(ids)

        rows = items.map { |item| row_for(item, workflows[item.key], failed) }
        order(rows)
      end

      # CYRA-899 — first the kind of decision, in the order the filters list it, then the queue order
      # inside the group: oldest on top, and at the bottom what I already asked about.
      def order(rows)
        rows.sort_by do |row|
          [ STATE_ORDER.fetch(row.state, STATE_ORDER.size), *sort_value(row), row.waiting_reply? ? 1 : 0, row.since || @now ]
        end
      end

      # Rows without the value stay last in both directions.
      def sort_value(row)
        return [] unless @sort_key

        value = SORTS.fetch(@sort_key).call(row)
        return [ 1, 0 ] if value.nil?

        [ 0, @sort_desc ? -value : value ]
      end

      def group(rows)
        rows.chunk_while { |before, after| before.state == after.state }
            .map { |chunk| Group.new(state: chunk.first.state, rows: chunk) }
      end

      def phase_counts(rows)
        counts = rows.filter_map(&:step).tally
        PHASES.index_with { |step| counts.fetch(step, 0) }
      end

      def row_for(item, workflow, failed)
        phase = workflow && ::Agents::Workflows::PhaseResolver.phase(workflow, failed[workflow.id])
        blocked = blocked_phase(workflow, phase)
        # SEMPRE esplicita, mai vuota: senza, RunTimeline ripiega sui timestamp e dipinge «sei qui»
        # su una lavorazione ferma da giorni. Su una bloccata non è corrente nessuna: il segno è
        # rosso sulla fase che l'ha fermata.
        # Il passaggio in cui la lavorazione SI TROVA, con le stesse parole della colonna dello stato:
        # è quello che toglie di mezzo la traduzione a mente.
        #
        # Una lavorazione ferma o annullata non ha nessun «sei qui», e non serve una guardia apposta:
        # il loro passaggio è un'USCITA (`blocked`, `cancelled`), che nelle sei tappe non c'è. Cade da
        # sé, e una guardia in più sarebbe una riga che nessuna prova può far diventare rossa.
        current_step = phase && ::Agents::Workflows::PhaseResolver.stage(phase)
        blocked_step = blocked && ::Agents::Workflows::PhaseResolver.step_of_execution_phase(blocked)

        Row.new(item: item, ticket_id: workflow&.ticket_id,
                cells: cells_for(workflow, current_step, blocked_step))
      end

      # La fase su cui una revisione ha fermato la lavorazione. `blocked_phase` è la COLONNA che il
      # dominio scrive quando i tentativi si esauriscono: è l'autorità. L'ultimo tentativo respinto da
      # solo mente in due modi opposti — host morto, e i tentativi restano `stale` senza nessun
      # respinto; bocciatura vecchia di una fase poi superata, e segnerebbe rossa una fase approvata.
      def blocked_phase(workflow, phase)
        return nil unless phase == "review_blocked"

        workflow.blocked_phase.presence
      end

      # CYRA-619 — le celle si derivano dallo STATO della lavorazione, non da `RunTimeline`: quello
      # ragiona sulle fasi interne, e qui le colonne sono i sei passaggi del modello.
      #
      # Prima di dove si trova: fatto. Dove si trova: «sei qui». Dopo: non ancora. Una lavorazione
      # ferma o annullata non ha nessun «sei qui» — ha un segno rosso sul passaggio dove si è fermata,
      # che è la verità: dipingere «sei qui» su una lavorazione che non gira è dichiararla viva.
      def cells_for(workflow, current_step, blocked_step)
        index = PHASES.index(current_step)
        PHASES.each_with_index.map do |step, position|
          Cell.new(phase: step, state: cell_state(step, position, index, blocked_step),
                   openable: workflow.present?)
        end
      end

      def cell_state(step, position, index, blocked_step)
        return "failed" if step == blocked_step
        return "pending" if index.nil?
        return "done" if position < index
        return "current" if position == index

        "pending"
      end

      # --- La lavorazione dietro ogni riga ----------------------------------------------------

      # { chiave di riga => Agents::Workflow }. Le chiavi vengono dal Batch, cioè da righe già gated:
      # qui non si allarga niente, si risolve soltanto ciò che la coda ha già deciso di mostrare.
      #
      # Tre famiglie su quattro una lavorazione ce l'hanno, e per strade diverse: il piano la nomina
      # nella chiave, la domanda ci arriva dal suo `Clarification`, la revisione dal ticket — e quasi
      # tutta la coda misurata in produzione è fatta di revisioni, quindi leggerle è la differenza fra
      # una plancia piena e una griglia di puntini spenti. Le richieste sui segreti non ne hanno.
      def workflows_by_key(items)
        keys = items.filter_map(&:key).group_by { |key| key.split(":", 2).first }
        plan_ids = ids_in(keys["agent_plan"])
        clarifications = clarification_workflow_ids(ids_in(keys["clarification"]))
        review_ticket_ids = ids_in(keys["review"])

        by_id = load_workflows(plan_ids + clarifications.values, review_ticket_ids)
        items.each_with_object({}) do |item, acc|
          workflow = workflow_for(item, by_id, clarifications)
          acc[item.key] = workflow if workflow
        end
      end

      def workflow_for(item, by_id, clarifications)
        family, id = item.key.to_s.split(":", 2)
        case family
        when "agent_plan" then by_id[:by_id][id]
        when "clarification" then by_id[:by_id][clarifications[id]]
        when "review" then by_id[:by_ticket][id]
        end
      end

      def ids_in(keys) = keys.to_a.filter_map { |key| key.split(":", 2).last.presence }

      # { clarification_id => workflow_id }: una pluck, non un preload di record interi — di quelle
      # righe serve solo il filo che porta alla lavorazione.
      def clarification_workflow_ids(ids)
        return {} if ids.empty?

        ::Agents::Clarification.where(id: ids).pluck(:id, :workflow_id).to_h
      end

      # Due query bounded, non un OR: una per le lavorazioni nominate (piani e domande) e una per
      # quelle appese ai ticket in revisione. Gli id arrivano come stringhe dalle chiavi, quindi le
      # mappe si indicizzano per stringa.
      def load_workflows(ids, ticket_ids)
        by_id = ids.compact.uniq.any? ? ::Agents::Workflow.where(id: ids.compact.uniq).index_by { |w| w.id.to_s } : {}
        by_ticket = if ticket_ids.any?
                      ::Agents::Workflow.where(ticket_id: ticket_ids).index_by { |w| w.ticket_id.to_s }
        else
                      {}
        end
        { by_id: by_id, by_ticket: by_ticket }
      end
    end
  end
end
