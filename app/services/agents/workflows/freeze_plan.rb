# frozen_string_literal: true

module Agents
  module Workflows
    # Approving a plan freezes it: which repository the work may start on and the proof that says done
    # (CYRA-610), and which plan version was approved. Shared by the CTO and the council (CYRA-1133).
    module FreezePlan
      # CYRA-1319 — a v3 plan also writes its proposed items into the ticket (Plans::TicketItems).
      def self.call(workflow:, plan:, actor:, now:)
        Agents::Plans::TicketItems.adopt!(plan, workflow.ticket)
        decision = Agents::Plan.decision_for(workflow.ticket)
        frozen = decision.frozen? ? { candidate_items: decision.candidate_items, completion_probe: decision.completion_probe } : {}
        plan.update!(approved_by: actor, approved_at: now, **frozen)
        workflow.update!(approved_by: actor, approved_at: now, frozen_plan_id: plan.id,
                         plan_frozen_at: now, **Agents::Workflow.cleared_block(now))
      end
    end
  end
end
