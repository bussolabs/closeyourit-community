# frozen_string_literal: true

module Ticketing
  # Passata B della compattazione (CYRA-222): riscrive UN commento storico lungo come riassunto entro
  # il tetto, conservando l'integrale in `original_body`.
  #
  # Presuppone che la passata A sia già passata su quel ticket: il testo integrale è già in una
  # versione del resoconto, quindi qui non si può perdere niente nemmeno sbagliando.
  class CompactCommentJob < ApplicationJob
    queue_as :ai

    # Attesa in minuti con jitter, non in secondi: contro un 429 il retry rapido di ApplicationJob
    # brucia i tentativi mentre la finestra del provider è ancora chiusa, e il jitter evita che N job
    # falliti nello stesso istante riprovino nello stesso istante (successo davvero il 2026-07-29).
    # Il filtro è TransientFailure e non AppError (CYRA-713): un errore definitivo — un dato che
    # non andrà mai bene — qui costerebbe sei chiamate al modello per ottenere lo stesso esito.
    # Comprende però anche i guasti di rete, che un codice non ce l'hanno: il log lo chiede con
    # `try`, altrimenti l'ultimo tentativo morirebbe di NoMethodError coprendo il guasto vero.
    retry_on TransientFailure,
             wait: ->(executions) { (executions**2).minutes + rand(0..59).seconds },
             attempts: MAX_ATTEMPTS = 6 do |job, error|
      Rails.logger.warn("[comment-compaction] abbandonato #{job.arguments.first[:comment_id]}: #{error.try(:code) || error.class}")
    end

    def perform(comment_id:)
      comment = Ticketing::Comment.find_by(id: comment_id)
      return if comment.nil? # cancellato fra enqueue ed esecuzione
      Current.organization = comment.ticket.project.organization # runs with this organization's AI settings (CYRA-914)

      # Guardie ri-valutate QUI, non solo all'enqueue: un job ri-accodato su un commento già fatto
      # costa una SELECT invece di una chiamata al modello.
      return if comment.compacted_at.present?
      return mark_done(comment) if comment.body.to_s.length <= Ticketing::Constants::COMMENT_MAX_CHARS

      # Il god ha tirato il freno a metà backfill: fermarsi, non ripiegare sul troncamento. Spegnere
      # deve voler dire "smetti", non "continua peggio". Il rake si rilancia quando riaccende.
      return if Ai::Feature.disabled?(:comment_compaction)

      compact(comment)
    end

    private

    def organization_id_of(comment) = comment.ticket.project.organization_id

    def compact(comment)
      version = Ticketing::Report.find_by(source_comment_id: comment.id)&.version
      result = Ticketing::SummarizeComment.call(body: comment.body, report_version: version,
                                                organization: organization_id_of(comment))

      # Ultimo tentativo: si ripiega sul troncamento del testo VERO invece di lasciare per sempre un
      # commento non compattato. Prima dell'ultimo si rilancia, così il retry_on fa il suo lavoro.
      if result.err?
        raise result.error unless last_attempt?

        return write(comment, Ticketing::SummarizeComment.fallback(body: comment.body, report_version: version))
      end

      write(comment, result.value)
    end

    def last_attempt? = executions >= MAX_ATTEMPTS

    # update_columns e non update!: una riscrittura di dati non deve rieseguire le validazioni del
    # model. In particolare Attachable rivaliderebbe i blob LEGACY contro le costanti di OGGI, e un
    # allegato di un tipo non più ammesso farebbe fallire la compattazione di quel commento senza che
    # il messaggio spieghi perché. Bypassa anche qualunque callback futuro, che qui è ciò che si vuole.
    def write(comment, body)
      comment.update_columns(body: body, original_body: comment.body, compacted_at: Time.current)
    end

    def mark_done(comment)
      comment.update_columns(compacted_at: Time.current)
    end
  end
end
