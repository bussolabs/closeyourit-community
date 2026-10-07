# frozen_string_literal: true

module Agents
  module Supporters
    # CYAU-235 — the clarification round a machine's supporter should answer next: open, on a project of the
    # machine's organization with the supporter on, on live work, and not yet decided at this version of its
    # questions. The digest pins that version: answers to questions that changed meanwhile are refused.
    class NextRound < ApplicationService
      def self.digest(round, questions)
        "sha256:" + Digest::SHA256.hexdigest(JSON.generate([ round.id, questions.map { |q| [ q.id, q.body, q.options ] } ]))
      end

      def initialize(host:)
        @host = host
      end

      def call
        Result.ok(candidates.lazy.filter_map { |round| item(round) }.first)
      end

      private

      def candidates
        Agents::Clarification.joins(workflow: { ticket: :project })
          .where(answered_at: nil, agents_workflows: { cancelled_at: nil, completed_at: nil })
          .where(projects: { organization_id: @host.organization_id, supporter_enabled: true })
          .includes(workflow: { ticket: :project }).order(:created_at).limit(20)
      end

      # OpenCode answers with the organization's OpenRouter model, like it reviews.
      def model = (Agents::AutomatorSetting.for(@host.organization).opencode_model if @host.effective_supporter == "opencode")

      def item(round)
        questions = round.questions.where(answered_at: nil, closed_at: nil).to_a
        return if questions.empty?

        digest = self.class.digest(round, questions)
        return if SupporterDecision.exists?(target_type: "question", target_id: questions.map(&:id), target_digest: digest)

        ticket = round.workflow.ticket
        { round_id: round.id, digest: digest, engine: @host.effective_supporter, project_key: ticket.project.key,
          ticket: { code: ticket.code, title: ticket.title, description: ticket.description.to_s },
          questions: questions.map { |q| { id: q.id, position: q.position, body: q.body, options: q.choice_options } },
          autonomous_max: RiskScore::AUTONOMOUS_MAX, model: model }
      end
    end
  end
end
