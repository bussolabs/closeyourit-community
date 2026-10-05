# frozen_string_literal: true

module Ticketing
  # Gate hard delle dipendenze (CYRA-81): un ticket con prerequisiti (blocker) non ancora "done" NON
  # può entrare in uno status di category in_progress o done. È il choke-point condiviso invocato da
  # Ticketing::ChangeStatus, Ticketing::ApproveReview e — per il ramo closer post-autopilot —
  # Agents::Workflows::ApproveAutopilot, sempre col TARGET RISOLTO (mai assunto done): il target di una
  # review può essere done (chiusura) oppure in_progress (avanzamento ai closer), entrambi gated.
  #
  # ANTI-RACE: DEVE girare DENTRO la transazione del cambio stato. Prende un SELECT ... FOR UPDATE su
  # ticket + blocker (id ORDINATI: anti-deadlock, stesso ordine di Connections::TicketDependency) e
  # SOLO DOPO rivaluta i prerequisiti — un blocker riaperto tra check e commit aspetta il lock e viene
  # visto non-done, senza finestra. Il lock resta fino al commit del cambio stato che lo racchiude.
  class DependencyGuard < ApplicationService
    # Quanti prerequisiti aperti elencare nel dettaglio dell'errore: gli altri restano nel conteggio
    # totale (open_count). Un elenco lungo non aiuta chi legge e gonfia il payload.
    LIST_LIMIT = 5

    # CYRA-623 — quale domanda si fa ai prerequisiti, fase per fase. Sta QUI, accanto al `mode`, e non
    # nella coda: la coda deve fare la STESSA domanda del cancello, altrimenti serve ticket che il
    # cancello poi rifiuta — e il giro di macchina è già stato pagato per intero.
    #
    # Per cominciare a lavorare basta che il codice del prerequisito sia unito e controllato: così due
    # ticket messi in fila escono con lo stesso rilascio. Per rilasciare in produzione no: lì l'ordine
    # che una persona ha deciso va rispettato alla lettera, e il prerequisito dev'essere vivo là.
    MODE_BY_PHASE = {
      "triage" => :merged, "planner" => :merged, "autopilot" => :merged,
      "closer_staging" => :merged, "closer_production" => :released
    }.freeze

    # Fail-closed: una fase che nessuno ha mappato fa la domanda severa. Il contrario vorrebbe dire
    # che una fase nuova nasce più permissiva del cancello senza che nessuno l'abbia deciso.
    def self.mode_for(execution_phase) = MODE_BY_PHASE.fetch(execution_phase.to_s, :released)

    # CYRA-623 — i prerequisiti aperti, ordinati e limitati, in un'UNICA query e SENZA lock: li dice
    # l'errore del cancello e li dice la scheda del ticket, e devono dire gli stessi codici nello
    # stesso ordine. Due elenchi composti in due punti diversi si sarebbero messi d'accordo per caso
    # finché uno dei due non cambiava un `order`.
    def self.open_dependencies(ticket, mode: :released)
      ticket.unmet_dependencies(mode:)
            .joins(blocker: :project)
            .order("ticketing_tickets.number")
            .limit(LIST_LIMIT)
            .pluck("ticketing_tickets.id", "projects.key", "ticketing_tickets.number", "ticketing_tickets.title")
            .map { |id, key, number, title| { id:, code: "#{key}-#{number}", title: } }
    end

    # Category che il gate protegge. L'enum Types::TicketStatus#category ha solo open/in_progress/done:
    # "non-open" è esattamente questi due, ma lo rendiamo esplicito invece di negare open.
    GATED_CATEGORIES = %w[in_progress done].freeze

    # CYRA-622 — `mode` è QUALE domanda si fa al prerequisito, e non è la stessa per tutti.
    # `:released` (default, invariato per ChangeStatus/ApproveReview/blocked_ids_among): il
    # prerequisito dev'essere Fatto. `:merged`: basta che il suo codice sia unito e provato — è la
    # domanda dell'approvazione del lavoro, che altrimenti costerebbe un giro di rilascio intero a
    # ogni coppia di ticket messi in fila.
    def initialize(ticket:, target_category:, mode: :released)
      @ticket = ticket
      @target_category = target_category.to_s
      @mode = mode.to_sym
    end

    def call
      # Movimento verso uno status open sempre permesso: il gate riguarda solo l'ingresso in
      # in_progress/done. Caso caldo (drag tra colonne "da fare") → nessun lock, nessuna query.
      return Result.ok(@ticket) unless GATED_CATEGORIES.include?(@target_category)

      lock_dependency_graph
      open_count = unmet.count
      return Result.ok(@ticket) if open_count.zero?

      Result.err(blocked_error(open_count))
    end

    private

    def unmet = @ticket.unmet_dependencies(mode: @mode)

    # SELECT ... FOR UPDATE su ticket + blocker, id ORDINATI: due cambi stato che toccano gli stessi
    # ticket lockano nello stesso ordine (no deadlock) e si serializzano (pattern Connections::
    # TicketDependency). Preso PRIMA di rivalutare i prerequisiti così un blocker riaperto in
    # concorrenza aspetta il commit e viene visto non-done.
    def lock_dependency_graph
      ids = ([ @ticket.id ] + @ticket.blockers.pluck(:id)).uniq.sort
      Ticketing::Ticket.where(id: ids).order(:id).lock.load
    end

    # Elenco limitato dei prerequisiti aperti in un'UNICA query: join blocker+progetto per comporre il
    # code (key-number) e leggere il title senza N+1 (nessun caricamento per riga). open_count è il
    # totale (già letto), remaining implicito = open_count - dependencies.size.
    def blocked_error(open_count)
      dependencies = self.class.open_dependencies(@ticket, mode: @mode)

      AppError.new(
        I18n.t("member.tickets.errors.blocked_by_dependencies", count: open_count),
        code: "R422-TICKET-014",
        details: { open_count: open_count, dependencies: dependencies }
      )
    end
  end
end
