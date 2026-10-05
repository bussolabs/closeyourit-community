# frozen_string_literal: true

module Ticketing
  # Archivia l'analisi tecnica di UN ticket storico (CYRA-260): markdown allegato + spiegazione nel
  # campo. Gemello di Ticketing::CompactCommentJob, e cadenzato per la stessa ragione — chiama un
  # modello, e il vincolo non è il nostro throughput ma il rate limit del provider.
  #
  # L'ordine rispetto alla compattazione dei commenti è indifferente: il testo si legge da
  # Ticketing::Comment#full_body, che è l'integrale anche dopo che la passata B ha ridotto il corpo
  # al riassunto.
  class ArchiveAnalysisJob < ApplicationJob
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
      Rails.logger.warn("[analysis-archive] abbandonato #{job.arguments.first[:ticket_id]}: #{error.try(:code) || error.class}")
    end

    def perform(ticket_id:)
      ticket = Ticketing::Ticket.find_by(id: ticket_id)
      return if ticket.nil? # cancellato fra enqueue ed esecuzione
      Current.organization = ticket.project.organization # runs with this organization's AI settings (CYRA-914)

      # Guardia ri-valutata QUI e non solo all'enqueue: un job ri-accodato su un ticket già archiviato
      # costa una SELECT invece di una chiamata al modello.
      return if ticket.analysis_recomposed_at.present?

      # Il god ha tirato il freno a metà backfill: fermarsi, non ripiegare sul troncamento. Spegnere
      # deve voler dire "smetti", non "continua peggio". Il rake si rilancia quando riaccende.
      return if Ai::Feature.disabled?(:comment_compaction)

      # Ripiego solo all'ultimo tentativo, come CompactCommentJob: prima si rilancia, così il
      # retry_on fa il suo lavoro e un provider con un brutto minuto non lascia analisi troncate.
      result = Ticketing::ArchiveTechnicalAnalysis.call(ticket: ticket, fallback: last_attempt?)
      # R422-ANALYSIS-001 = la spiegazione non sta nel campo: è un ticket da guardare a mano, non un
      # errore da riprovare. Riprovarlo darebbe lo stesso esito per sei volte.
      return if result.ok? || result.error.code == "R422-ANALYSIS-001"

      raise result.error
    end

    private

    def last_attempt? = executions >= MAX_ATTEMPTS
  end
end
