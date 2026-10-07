# frozen_string_literal: true

module Agents
  module Supporters
    # CYAU-235 — the supporter proposes, the server decides. A round is answered only when EVERY open question
    # passes the server's own checks; otherwise the whole round goes to a person and nothing is answered.
    # The checks never trust the model: the score is raised by the server's rules and never lowered, reserved
    # topics are matched here, and an answer without a written source needs high confidence. Every outcome,
    # answered or handed over, is written to the ledger; answered ones wait in "To review".
    class AnswerRound < ApplicationService
      SettleRefused = Class.new(StandardError)
      CONFIDENCES = %w[low medium high].freeze
      SOURCE_STATUSES = %w[written no_written_source].freeze

      def initialize(host:, round_id:, payload:)
        @host = host
        @round_id = round_id
        @payload = payload.to_h.deep_stringify_keys
      end

      def call
        return error("R404-SUPPORTER-001", :not_found) if round.nil?
        return error("R403-SUPPORTER-001", :disabled) unless project.supporter_enabled?
        return error("R409-SUPPORTER-002", :no_service_account) if @host.service_account.nil?

        digest = NextRound.digest(round, open_questions)
        return Result.ok(earlier(digest)) if decided?(digest)
        return error("R409-SUPPORTER-001", :stale) unless open_questions.any? && @payload["digest"] == digest

        verdicts = open_questions.map { |question| verdict(question) }
        outcome = verdicts.all? { |v| v[:reasons].empty? } ? "answered" : "escalated"
        ApplicationRecord.transaction do
          settle!(verdicts) if outcome == "answered"
          verdicts.each { |v| record!(v, digest, outcome == "answered" ? "answered" : "escalated") }
        end
        Result.ok(summary(outcome, verdicts))
      rescue SettleRefused
        error("R409-SUPPORTER-003", :not_settled)
      end

      private

      def round
        @round ||= Agents::Clarification.joins(workflow: { ticket: :project })
          .where(projects: { organization_id: @host.organization_id }).find_by(id: @round_id)
      end

      def project = round.workflow.ticket.project
      def ticket = round.workflow.ticket
      def open_questions = @open_questions ||= round.questions.where(answered_at: nil, closed_at: nil).to_a

      def decided?(digest) = SupporterDecision.exists?(target_type: "question", target_id: open_questions.map(&:id), target_digest: digest)

      def earlier(digest)
        decisions = SupporterDecision.where(target_type: "question", target_id: open_questions.map(&:id), target_digest: digest)
        outcome = decisions.all? { |d| d.outcome == "answered" } ? "answered" : "escalated"
        { outcome: outcome, questions: decisions.map { |d| { id: d.target_id, risk_score: d.risk_score, outcome: d.outcome } } }
      end

      def verdict(question)
        proposal = Array(@payload["answers"]).find { |a| a.is_a?(Hash) && a["question_id"].to_s == question.id.to_s } || {}
        body, choice = chosen(question, proposal)
        text = [ ticket.title, ticket.description, question.body, body ].join("\n")
        reserved = topics.match(text: text)
        score = RiskScore.resolve(previous: nil, proposed: proposal["risk_score"], reserved: reserved.any?)
        { question:, proposal:, body:, choice:, score:, reserved: reserved.map(&:value),
          reasons: reasons(question, proposal, body, choice, score, reserved) }
      end

      def chosen(question, proposal)
        return [ question.choice_label(proposal["choice"].to_i), proposal["choice"].to_i ] if proposal["choice"].present?

        [ proposal["text"].to_s.strip.presence, nil ]
      end

      def reasons(question, proposal, body, choice, score, reserved)
        [].tap do |list|
          list << "no_answer" if body.blank? && choice.nil?
          list << "invalid_choice" if choice && body.nil?
          list << "risk_above_threshold" unless RiskScore.autonomous?(score)
          list << "reserved_topic" if reserved.any?
          list << "unknown_source_status" unless SOURCE_STATUSES.include?(proposal["source_status"])
          list << "low_confidence" unless confident?(proposal)
        end
      end

      # A written source needs at least medium confidence; no written source needs high.
      def confident?(proposal)
        return false unless CONFIDENCES.include?(proposal["confidence"])

        proposal["source_status"] == "written" ? proposal["confidence"] != "low" : proposal["confidence"] == "high"
      end

      def topics = @topics ||= ReservedTopics.new(organization: project.organization, project: project)

      def settle!(verdicts)
        answers = round.questions.order(:position, :created_at).map do |question|
          verdict = verdicts.find { |v| v[:question].id == question.id }
          verdict && { body: verdict[:body], choice: verdict[:choice] }
        end
        result = Agents::Clarifications::Settle.call(clarification: round, author: @host.service_account,
                                                     answers: answers, origin: :agent)
        raise SettleRefused, result.error.message unless result.ok?
      end

      def record!(verdict, digest, outcome)
        SupporterDecision.create!(
          organization: project.organization, workflow: round.workflow, target_type: "question",
          target_id: verdict[:question].id, target_digest: digest, outcome: outcome,
          engine: @host.effective_supporter, risk_score: verdict[:score],
          evidence: verdict[:proposal].merge("reserved_matches" => verdict[:reserved], "reasons" => verdict[:reasons],
                                             "answer" => verdict[:body])
        )
      end

      def summary(outcome, verdicts)
        { outcome: outcome, questions: verdicts.map { |v| { id: v[:question].id, risk_score: v[:score], reasons: v[:reasons] } } }
      end

      def error(code, key)
        status = { "R404" => :not_found, "R403" => :forbidden, "R409" => :conflict }.fetch(code[0, 4])
        Result.err(AppError.new(I18n.t("agents.supporter.errors.#{key}"), code: code, status: status))
      end
    end
  end
end
