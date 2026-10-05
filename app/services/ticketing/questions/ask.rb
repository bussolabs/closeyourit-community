# frozen_string_literal: true

module Ticketing
  module Questions
    # Pone una domanda su un ticket (CYRA-779).
    #
    # Chiedere è baseline: è una conversazione, non una decisione sul lavoro. Marcare la domanda
    # BLOCCANTE invece ferma la coda degli agenti, quindi è una leva sul lavoro e il controllo del
    # permesso vive nel chiamante — qui il servizio si limita a registrare ciò che gli viene chiesto.
    #
    # Non notifica nessuno, e non è una dimenticanza: la catena di avviso di un ticket tocca sei file
    # (tipo di evento, contenuto, preferenze, consegna, mailer, dispatcher) e cinque su sei fanno un
    # avviso che non arriva a nessuno. Si fa intera con la pagina che permette di scrivere una domanda
    # (CYRA-782). Fino a lì nessuna strada arriva qui, quindi non c'è niente che possa restare muto.
    class Ask < ApplicationService
      def initialize(ticket:, author:, body:, blocking: false, audience: :internal,
                     origin: :human, round: nil, position: 0)
        @ticket = ticket
        @author = author
        @body = body
        @blocking = blocking
        @audience = audience
        @origin = origin
        @round = round
        @position = position
      end

      def call
        question = @ticket.questions.new(
          author: @author, body: @body, blocking: @blocking, audience: @audience,
          origin: @origin, round_id: @round&.id, position: @position
        )
        return invalid(question) unless question.save

        # Dentro nessuna transazione aperta dal chiamante: la cronologia si scrive dopo il salvataggio
        # riuscito, ed è ciò che rende la domanda visibile nella storia del ticket anche prima che
        # esista una pagina che la mostri.
        Ticketing::RecordActivity.call(
          ticket: @ticket, action: "question_asked", actor: @author,
          data: { question_id: question.id, blocking: question.blocking }
        )
        Result.ok(question)
      end

      private

      def invalid(question)
        Result.err(AppError.new(I18n.t("member.tickets.questions.errors.invalid"),
                                code: "R422-QUESTION-001", details: question.errors.to_hash))
      end
    end
  end
end
