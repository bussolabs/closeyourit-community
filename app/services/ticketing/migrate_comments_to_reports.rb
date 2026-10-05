# frozen_string_literal: true

module Ticketing
  # Passata A della compattazione (CYRA-222): mette al sicuro il testo, senza chiamare nessun modello.
  #
  # Per ogni ticket, i commenti lunghi classificati come resoconto diventano versioni del resoconto in
  # ordine cronologico, con il corpo VERBATIM. Nient'altro: nessuna riscrittura, nessuna riga di
  # servizio inventata a posteriori (il commento compattato È la traccia storica; annunciare oggi
  # "resoconto aggiornato alla versione 2" su fatti di due mesi fa falsificherebbe la timeline).
  #
  # Separata dalla passata B — che è quella che chiama l'AI — perché il testo deve essere al sicuro
  # PRIMA e INDIPENDENTEMENTE dalla riuscita di centinaia di chiamate a un provider che il 2026-07-29
  # ha risposto 429 per 327 volte di fila.
  class MigrateCommentsToReports < ApplicationService
    def initialize(ticket:)
      @ticket = ticket
    end

    # Ritorna le versioni create in questa passata (vuoto se non c'era niente da spostare o se era
    # già stato fatto).
    def call
      created = []
      ApplicationRecord.transaction do
        @ticket.lock!
        migratable.each do |comment|
          version = version_for(comment)
          created << version if version
        end
      end
      Result.ok(created)
    end

    private

    # Solo i resoconti: le domande hanno già casa nelle righe di primo livello e duplicarle in
    # una versione di resoconto sarebbe rumore; i commenti corti non hanno niente da spostare.
    def migratable
      comments = @ticket.comments.order(:created_at).to_a
      question_ids = Agents::Clarification.where(question_comment_id: comments.map(&:id))
                                          .pluck(:question_comment_id)
      comments.select do |comment|
        Ticketing::CommentShape.call(comment: comment, question_comment_ids: question_ids) == :report
      end
    end

    # Idempotenza in DB, non in memoria: l'indice unico parziale su source_comment_id impedisce il
    # doppione anche se due esecuzioni si sovrappongono, e questa find_by evita di provarci.
    def version_for(comment)
      return if Ticketing::Report.exists?(source_comment_id: comment.id)

      @ticket.reports.create!(
        body: comment.body, author: comment.author, author_name: comment.author&.name,
        source: :migrated, source_comment: comment, version: next_version,
        created_at: comment.created_at, updated_at: comment.created_at
      )
    end

    # Numero assegnato a mano invece che da assign_version: dentro la transazione le versioni appena
    # create non sono ancora visibili a un maximum() su un'altra connessione, e soprattutto così la
    # numerazione ricalca l'ordine cronologico dei commenti anche su un retry parziale.
    def next_version
      @next_version = (@next_version || @ticket.reports.maximum(:version).to_i) + 1
    end
  end
end
