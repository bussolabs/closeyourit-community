# frozen_string_literal: true

require "rails_helper"

# CYRA-1329 — a stop with no reason must not be able to exist. On 2026-11-19 the decision queue held
# 74 pieces of work stopped with nothing written next to them: whoever had to decide could not tell
# what to do, and the row stayed there. The rule lives in the DATABASE and not only in a service
# because every path that stops a piece of work writes these same four columns, and the next one
# written will forget.
RSpec.describe "Agents::Workflow — a stop always says why", type: :model do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:) }
  let(:workflow) do
    create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago, triage_started_at: 1.day.ago,
                            triaged_at: 20.hours.ago)
  end

  def write_block(reason)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      UPDATE agents_workflows
         SET blocked_at = NOW(), blocked_phase = 'planner', blocked_kind = 'attempt_limit',
             blocked_reason = #{reason.nil? ? 'NULL' : ActiveRecord::Base.connection.quote(reason)}
       WHERE id = '#{workflow.id}'
    SQL
  end

  describe "the database refuses a stop without a reason" do
    it "refuses a block with no reason at all" do
      expect { write_block(nil) }
        .to raise_error(ActiveRecord::StatementInvalid, /blocco_ha_un_motivo/)
    end

    it "refuses a block whose reason is only blanks" do
      expect { write_block("   ") }
        .to raise_error(ActiveRecord::StatementInvalid, /blocco_ha_un_motivo/)
    end

    it "accepts a block that says why" do
      expect { write_block("attempt_limit: planner failed 2 times") }.not_to raise_error
      expect(workflow.reload.blocked_reason).to be_present
    end

    # Clearing the block clears the reason with it: the constraint must not stand in the way of the
    # one write that makes the pair empty again.
    it "lets a cleared block go back to empty" do
      write_block("attempt_limit: planner failed 2 times")

      expect { workflow.reload.update!(Agents::Workflow.cleared_block) }.not_to raise_error
      expect(workflow.reload.blocked_at).to be_nil
    end
  end

  describe "#stop_reason" do
    it "is nil while the work is running" do
      expect(workflow.stop_reason).to be_nil
    end

    it "reads the written block" do
      Agents::Workflows::Block.call(workflow:, phase: "planner", kind: "attempt_limit",
                                    reason: "attempt_limit: planner failed 2 times")

      expect(workflow.reload.stop_reason).to have_attributes(kind: "attempt_limit", phase: "planner")
    end

    # AC-6 / CYRA-267 — rejected under the attempts cap: nothing is written in blocked_*, and this is
    # the row that had nothing to show.
    it "reads a phase stopped under the attempts cap" do
      # Triage claimed and never closed: the queue stops proposing it, and no block is written.
      stalled = create(:agent_workflow, ticket: create(:ticket, organization:, project:),
                                        triage_requested_at: 2.days.ago, triage_started_at: 1.day.ago)
      create(:agent_attempt, workflow: stalled, organization:, phase: "triage", status: :review_failed)

      expect(stalled.stop_reason)
        .to have_attributes(kind: Agents::StopReason::STALLED_KIND, phase: "triage")
    end
  end
end
