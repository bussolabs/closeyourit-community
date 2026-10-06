# frozen_string_literal: true

module Ticketing
  module Questions
    # Ritira una domanda senza risposta (CYRA-779).
    #
    # Serve perché una domanda BLOCCANTE trattiene il ticket: senza una strada per ritirarla, una
    # domanda posta per sbaglio — o superata dai fatti — fermerebbe il lavoro finché qualcuno non
    # inventa una risposta pur di sbloccarlo. Il ritiro è una riga di cronologia, non una
    # cancellazione: la domanda resta leggibile, e si vede che nessuno ha risposto.
    class Close < ApplicationService
      def initialize(question:, actor:)
        @question = question
        @actor = actor
      end

      def call
        # Only the one who asked withdraws: someone else's question is answered, not dropped.
        return not_author unless @question.author_id == @actor.id
        return already_answered if @question.answered_at?
        return Result.ok(@question) if @question.closed_at?

        @question.update!(closed_at: Time.current, closed_by: @actor)
        Ticketing::RecordActivity.call(
          ticket: @question.ticket, action: "question_closed", actor: @actor,
          data: { question_id: @question.id }
        )
        Result.ok(@question)
      end

      private

      def not_author
        Result.err(AppError.new(I18n.t("member.tickets.questions.errors.not_author"), code: "R403-QUESTION-003"))
      end

      def already_answered
        Result.err(AppError.new(I18n.t("member.tickets.questions.errors.already_answered"),
                                code: "R409-QUESTION-002"))
      end
    end
  end
end
