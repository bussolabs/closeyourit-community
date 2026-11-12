# frozen_string_literal: true

module Agents
  module Supporters
    # CYRA-1193 — the plan a machine's supporter should judge next: the newest version of a plan waiting for
    # approval, on live work of a project of the machine's organization with the supporter on, and not yet
    # judged at this version. The digest pins the version read: a verdict on a plan changed meanwhile is refused.
    class NextPlan < ApplicationService
      # Bumped when the supporter's options change, so plans judged under the old rules are read once more.
      # 2: the supporter can send a plan back to the planner (CYRA-1197).
      # 3: a change customers see is no longer maximum risk by itself (CYRA-1197).
      # 4: a gate named in a prohibition ("do not skip checks") is no longer read as a bypass.
      # 5: the supporter decides alone up to risk 8; sensitive paths rise to 9 (CYRA-1197).
      # 7: a gate listed after a forbidden one ("do not use --no-verify or [skip ci]") is no longer a bypass.
      # 8: a plan that changes CI workflow files goes back to the planner instead of to a person (CYRA-1197).
      # 9: low-risk plans are approved after the last revision, with the gaps as notes (CYRA-1197).
      DIGEST_VERSION = 9

      def self.digest(plan)
        "sha256:" + Digest::SHA256.hexdigest(JSON.generate([ DIGEST_VERSION, plan.id, plan.version, document(plan) ]))
      end

      # What the supporter reads: the plan as the person approving it reads it, with its Definition of Done.
      def self.document(plan)
        doc = plan.document
        # CYRA-1298 — a criterion that says how it is proven is judged with its proof; one that does not reads as before.
        done = doc.definition_of_done.map do |criterion|
          proof = criterion["verification"]
          "- #{criterion["text"]}#{" (verified by #{proof["kind"]}: #{proof["how"]})" if proof}"
        end
        [ doc.technical_analysis.to_s, (done.any? ? "### Definition of Done\n#{done.join("\n")}" : nil) ].compact.join("\n\n")
      end

      def initialize(host:)
        @host = host
      end

      # Every waiting plan, not a fixed window: the oldest may all be judged already, and the next one to
      # judge can sit far behind them. Three queries whatever the backlog: workflows, latest plans, verdicts.
      def call
        workflows = candidates.to_a
        plans = latest_plans(workflows)
        judged = judged_digests(plans.values)
        workflows.each do |workflow|
          plan = plans[workflow.id]
          next if plan.nil? || plan.approved_at? || plan.change_request.present?

          digest = self.class.digest(plan)
          next if judged.include?([ plan.id, digest ]) || OfferLimit.resting?(@host, digest)

          OfferLimit.offered!(@host, digest)
          return Result.ok(item(workflow, plan, digest))
        end
        Result.ok(nil)
      end

      private

      def candidates
        Agents::Workflow.joins(ticket: :project)
          .where(cancelled_at: nil, completed_at: nil, blocked_at: nil, approved_at: nil)
          .where.not(planned_at: nil)
          .where(projects: { organization_id: @host.organization_id, supporter_enabled: true })
          .where(FollowedProjects.condition(@host))
          .includes(ticket: :project).order(:planned_at, :id)
      end

      def latest_plans(workflows)
        Agents::Plan.where(workflow_id: workflows.map(&:id))
          .select("DISTINCT ON (agents_plans.workflow_id) agents_plans.*")
          .reorder(:workflow_id, version: :desc).index_by(&:workflow_id)
      end

      def judged_digests(plans)
        SupporterDecision.where(target_type: "plan", target_id: plans.map(&:id)).pluck(:target_id, :target_digest).to_set
      end

      # OpenCode judges with the organization's OpenRouter model, like it reviews.
      def model = (Agents::AutomatorSetting.for(@host.organization).opencode_model if @host.effective_supporter == "opencode")

      def item(workflow, plan, digest)
        ticket = workflow.ticket
        { plan_id: plan.id, digest: digest, engine: @host.effective_supporter, project_key: ticket.project.key,
          ticket: { code: ticket.code, title: ticket.title, description: ticket.description.to_s },
          plan: { version: plan.version, document: self.class.document(plan) },
          autonomous_max: RiskScore::AUTONOMOUS_MAX, model: model }
      end
    end
  end
end
