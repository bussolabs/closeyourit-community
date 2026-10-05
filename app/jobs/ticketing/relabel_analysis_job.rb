# frozen_string_literal: true

module Ticketing
  # Riscrive a etichette l'analisi tecnica di UN ticket (CYRA-266). Gemello di
  # Ticketing::ArchiveAnalysisJob e cadenzato per la stessa ragione: chiama un modello, e il vincolo
  # non è il nostro throughput ma il rate limit del provider.
  #
  # Differenza che conta: **nessun ripiego all'ultimo tentativo**. Là il testo integrale era già
  # nell'allegato e troncare era meglio di niente; qui si riscrive l'unica copia di un testo già
  # leggibile. Sei tentativi falliti significano che il ticket resta com'era e non viene marcato —
  # il rilancio del rake lo riprende.
  class RelabelAnalysisJob < ApplicationJob
    queue_as :ai

    # Attesa in minuti con jitter, non in secondi: contro un 429 il retry rapido di ApplicationJob
    # brucia i tentativi mentre la finestra del provider è ancora chiusa.
    # Il filtro è TransientFailure e non AppError (CYRA-713): un errore definitivo — un dato che
    # non andrà mai bene — qui costerebbe sei chiamate al modello per ottenere lo stesso esito.
    # Comprende però anche i guasti di rete, che un codice non ce l'hanno: il log lo chiede con
    # `try`, altrimenti l'ultimo tentativo morirebbe di NoMethodError coprendo il guasto vero.
    retry_on TransientFailure,
             wait: ->(executions) { (executions**2).minutes + rand(0..59).seconds },
             attempts: MAX_ATTEMPTS = 6 do |job, error|
      Rails.logger.warn("[analysis-relabel] abbandonato #{job.arguments.first[:ticket_id]}: #{error.try(:code) || error.class}")
    end

    def perform(ticket_id:)
      ticket = Ticketing::Ticket.find_by(id: ticket_id)
      return if ticket.nil? # cancellato fra enqueue ed esecuzione
      Current.organization = ticket.project.organization # runs with this organization's AI settings (CYRA-914)

      # Guardia ri-valutata QUI e non solo all'enqueue: un job ri-accodato su un ticket già riscritto
      # costa una SELECT invece di una chiamata al modello.
      return if ticket.analysis_relabeled_at.present?

      # Il god ha tirato il freno a metà backfill: fermarsi. Spegnere deve voler dire "smetti".
      return if Ai::Feature.disabled?(:analysis_relabel)

      # Il ticket è in mano all'automazione: il corpo è bloccato (Agents::Workflow#body_locked?) e
      # UpdateTicket rifiuterebbe con R409-TICKET-006. Si salta SENZA marcare, così il rilancio lo
      # riprende quando la lavorazione è finita — forzarlo vorrebbe dire scrivere sopra il testo che
      # un agente sta usando come specifica in quel momento.
      return if ticket.agent_workflow&.body_locked?

      result = Ticketing::RelabelAnalysis.call(body: ticket.technical_analysis,
                                               organization: ticket.project.organization_id)
      raise result.error if result.err?

      # nil = non c'era niente da fare (campo vuoto, o già a etichette). Si marca lo stesso: il
      # ticket è a posto, e senza marcarlo ogni rilancio lo rivaluterebbe per sempre.
      apply(ticket, result.value)
    end

    private

    # Scrittura DIRETTA più evento a mano, non Ticketing::UpdateTicket. La cronologia serve — è dove
    # resta leggibile il testo di prima — ma UpdateTicket porta con sé anche la rivalutazione del gate
    # agenti (`enqueue_agent_eligibility if agent_eligibility_stale?`), e riscrivere l'analisi rende
    # stale ogni ticket toccato: 423 riscritture diventerebbero 423 chiamate IN PIÙ al provider, la
    # forma esatta dell'incidente del 2026-07-29 per cui esiste il freno d'emergenza. Stessa scelta,
    # per la stessa ragione, di Ticketing::ArchiveTechnicalAnalysis#write_summary.
    #
    # Il gate `body_locked?` che UpdateTicket applicherebbe è già ricontrollato in `perform`.
    def apply(ticket, analysis)
      return ticket.update_column(:analysis_relabeled_at, Time.current) if analysis.blank?

      previous = ticket.technical_analysis
      embedding_before = Ticketing::EmbeddingText.checksum(ticket: ticket)

      ApplicationRecord.transaction do
        ticket.update!(technical_analysis: analysis, analysis_relabeled_at: Time.current)
        # Stessa forma del diff di Ticketing::UpdateTicket#log_changes — coppia [prima, dopo] sotto
        # la chiave della colonna — così la cronologia lo rende come ogni altra modifica del corpo,
        # senza un ramo dedicato nel presenter. Non l'ha deciso una persona: l'autore è dichiarato
        # per nome (CYRA-406), perché «autore non registrato» su una modifica appena avvenuta si
        # legge come un buco dell'audit invece che come un'automazione.
        Ticketing::RecordActivity.call(ticket: ticket, action: "updated",
                                       actor_name: I18n.t("member.tickets.activity.system.analysis"),
                                       data: { "technical_analysis" => [ previous, analysis ] })
      end

      # Il re-embed non arriva da solo fuori da UpdateTicket, ed è il motivo per cui il checksum si
      # misura prima e dopo invece di riaccodare sempre.
      return if Ticketing::EmbeddingText.checksum(ticket: ticket) == embedding_before

      Ticketing::EmbedTicketJob.perform_later(ticket_id: ticket.id)
    end
  end
end
