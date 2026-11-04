# frozen_string_literal: true

module Agents
  module Supporters
    # CYRA-1193 — the plan a machine's supporter should judge next: the newest version of a plan waiting for
    # approval, on live work of a project of the machine's organization with the supporter on, and not yet
    # judged at this version. The digest pins the version read: a verdict on a plan changed meanwhile is refused.
    class NextPlan < ApplicationService
      def self.digest(plan)
        "sha256:" + Digest::SHA256.hexdigest(JSON.generate([ plan.id, plan.version, document(plan) ]))
      end

      # What the supporter reads: the plan as the person approving it reads it, with its Definition of Done.
      def self.document(plan)
        doc = plan.document
        done = doc.definition_of_done.map { |criterion| "- #{criterion["text"]}" }
        [ doc.technical_analysis.to_s, (done.any? ? "### Definition of Done\n#{done.join("\n")}" : nil) ].compact.join("\n\n")
      end

      def initialize(host:)
        @host = host
      end

      def call
        Result.ok(candidates.lazy.filter_map { |workflow| item(workflow) }.first)
      end

      private

      def candidates
        Agents::Workflow.joins(ticket: :project)
          .where(cancelled_at: nil, completed_at: nil, blocked_at: nil, approved_at: nil)
          .where.not(planned_at: nil)
          .where(projects: { organization_id: @host.organization_id, supporter_enabled: true })
          .includes(ticket: :project).order(:planned_at).limit(20)
      end

      # OpenCode judges with the organization's OpenRouter model, like it reviews.
      def model = (Agents::AutomatorSetting.for(@host.organization).opencode_model if @host.effective_supporter == "opencode")

      def item(workflow)
        plan = workflow.plans.reorder(version: :desc).first
        return if plan.nil? || plan.approved_at? || plan.change_request.present?

        digest = self.class.digest(plan)
        return if SupporterDecision.exists?(target_type: "plan", target_id: plan.id, target_digest: digest)

        ticket = workflow.ticket
        { plan_id: plan.id, digest: digest, engine: @host.effective_supporter, project_key: ticket.project.key,
          ticket: { code: ticket.code, title: ticket.title, description: ticket.description.to_s },
          plan: { version: plan.version, document: self.class.document(plan) },
          autonomous_max: RiskScore::AUTONOMOUS_MAX, model: model }
      end
    end
  end
end
