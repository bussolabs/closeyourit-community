# frozen_string_literal: true

module Ticketing
  module Questions
    # A person's answer to one question, from the Questions tab or the CLI. When the question belongs to
    # an open automator round it goes through Settle, the only place that closes a round and puts the
    # work back in the triage queue; otherwise it is a plain answer. CYRA-1002
    class Reply < ApplicationService
      # `choice` is the 1-based number of a proposed answer (CYRA-1033): the answer reads as its label and
      # remembers which one was clicked. A choice and typed text together are refused, not merged.
      def initialize(question:, author:, body:, choice: nil)
        @question = question
        @author = author
        @body = body
        @choice = choice.presence&.to_i
      end

      def call
        return invalid_choice if @choice && (@body.present? || @question.choice_label(@choice).nil?)

        body = @choice ? @question.choice_label(@choice) : @body
        round = open_round
        return Answer.call(question: @question, author: @author, body: body, choice_index: @choice) if round.nil?

        answers = round.questions.map { |question| question.id == @question.id ? { body: body, choice: @choice } : nil }
        result = Agents::Clarifications::Settle.call(clarification: round, author: @author, answers: answers)
        result.ok? ? Result.ok(@question.reload.resolved_answer) : result
      end

      private

      def invalid_choice
        Result.err(AppError.new(I18n.t("member.tickets.questions.errors.invalid_choice"), code: "R422-QUESTION-003"))
      end

      # A concluded ticket keeps today's behaviour: the answer is recorded, nothing restarts (CYRA-630).
      # A withdrawn question goes to Answer, which refuses it: Settle would close the round anyway.
      def open_round
        return if @question.round_id.blank? || @question.answered_at? || @question.closed_at?
        return if @question.ticket.status&.category_done?

        Agents::Clarification.find_by(id: @question.round_id, answered_at: nil)
      end
    end
  end
end
