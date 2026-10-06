# frozen_string_literal: true

module Ticketing
  module Questions
    # A person's answer to one question, from the Questions tab or the CLI. When the question belongs to
    # an open automator round it goes through Settle, the only place that closes a round and puts the
    # work back in the triage queue; otherwise it is a plain answer. CYRA-1002
    class Reply < ApplicationService
      def initialize(question:, author:, body:)
        @question = question
        @author = author
        @body = body
      end

      def call
        round = open_round
        return Answer.call(question: @question, author: @author, body: @body) if round.nil?

        answers = round.questions.map { |question| question.id == @question.id ? @body : nil }
        result = Agents::Clarifications::Settle.call(clarification: round, author: @author, answers: answers)
        result.ok? ? Result.ok(@question.reload.resolved_answer) : result
      end

      private

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
