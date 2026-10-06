# frozen_string_literal: true

module Ticketing
  module Questions
    # Risponde a UNA domanda (CYRA-779).
    #
    # È il punto del ticket: prima la risposta era il primo commento umano arrivato dopo la domanda,
    # e bastava commentare d'altro per chiuderla. Qui si risponde a una domanda che si nomina.
    #
    # `answered_at` si scrive SOTTO LOCK e solo se la domanda è ancora aperta: due risposte arrivate
    # insieme devono lasciare entrambe la loro riga, ma il momento in cui la domanda si è chiusa è uno
    # solo — ed è il primo. Senza il lock la seconda lo riscriverebbe, e la storia direbbe che la
    # domanda è rimasta aperta più di quanto è stata.
    class Answer < ApplicationService
      def initialize(question:, author:, body:, origin: :human, covers_round: false, choice_index: nil)
        @question = question
        @author = author
        @body = body
        @origin = origin
        @covers_round = covers_round
        @choice_index = choice_index
      end

      def call
        return closed if @question.closed_at?

        answer = @question.answers.new(author: @author, body: @body, origin: @origin,
                                       covers_round: @covers_round, choice_index: @choice_index)
        return invalid(answer) unless answer.valid?

        ApplicationRecord.transaction do
          answer.save!
          @question.lock!
          # Già risposta: la riga nuova resta (è la parola di qualcuno), ma non sposta il momento in
          # cui la domanda ha smesso di aspettare né la risposta che l'ha chiusa.
          next if @question.answered_at?

          @question.update!(answered_at: Time.current, resolved_answer: answer)
          Ticketing::RecordActivity.call(
            ticket: @question.ticket, action: "question_answered", actor: @author,
            data: { question_id: @question.id, answer_id: answer.id }
          )
        end
        Result.ok(answer)
      end

      private

      def closed
        Result.err(AppError.new(I18n.t("member.tickets.questions.errors.closed"),
                                code: "R409-QUESTION-001"))
      end

      def invalid(answer)
        Result.err(AppError.new(I18n.t("member.tickets.questions.errors.answer_invalid"),
                                code: "R422-QUESTION-002", details: answer.errors.to_hash))
      end
    end
  end
end
