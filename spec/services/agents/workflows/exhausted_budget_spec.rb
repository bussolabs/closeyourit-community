# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Workflows::ExhaustedBudget do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }

  def stop!(kind: "attempt_limit", phase: "autopilot")
    workflow.update!(blocked_at: Time.current, blocked_phase: phase, blocked_kind: kind,
                     blocked_reason: "#{kind}: #{phase} failed twice")
  end

  def attempt_on(engine)
    create(:agent_attempt, organization:, workflow:, phase: "autopilot", status: :review_failed, runtime: engine)
  end

  # AC-1, AC-4 — the attempts ran out for the first time: the work starts over on the other engine and
  # nothing is asked of a person.
  describe "the first time the attempts run out" do
    it "restarts the work from scratch on the other engine" do
      attempt_on("claude")
      stop!

      expect(described_class.call(workflow:)).to be_ok
      fresh = ticket.reload.agent_workflow
      expect(fresh.id).not_to eq(workflow.id)
      expect(fresh).to have_attributes(budget_restart_engine: "codex", triage_requested_at: be_present,
                                       blocked_at: nil, cancelled_at: nil)
    end

    # CYRA-1357 — an agent's own stop is settled the same way.
    it "restarts a stop the agent declared itself" do
      attempt_on("claude")
      stop!(kind: "agent_blocked")

      expect(described_class.call(workflow:).value).to eq(:restarted)
      expect(ticket.reload.agent_workflow.budget_restart_engine).to eq("codex")
    end

    it "hands the work to claude when codex is the engine that failed" do
      attempt_on("codex")
      stop!

      described_class.call(workflow:)

      expect(ticket.reload.agent_workflow.budget_restart_engine).to eq("claude")
    end

    it "keeps the ticket out of nobody's queue: no stop is left behind" do
      attempt_on("claude")
      stop!

      described_class.call(workflow:)

      expect(Agents::Workflow.where(id: workflow.id)).to be_empty
      expect(ticket.reload.agent_eligibility).not_to eq("blocked")
    end

    it "writes the restart in the ticket history, with the engine it was handed to" do
      attempt_on("claude")
      stop!

      described_class.call(workflow:)

      event = ticket.events.find_by(action: "workflow_restarted_other_engine")
      expect(event).to be_present
      expect(event.data["engine"]).to eq("codex")
    end

    # The lease outlives the run it was taken for (it belongs to the ticket): left behind, the new run
    # would find the ticket held by a machine that is no longer working on it.
    it "lets the ticket go: the machine's lease is released" do
      attempt = attempt_on("claude")
      create(:agent_lease, organization:, ticket:, host: attempt.host,
                           run_id: attempt.external_run_id, expires_at: 5.minutes.from_now)
      stop!

      described_class.call(workflow:)

      expect(ticket.reload.agent_lease).to be_nil
    end
  end

  # AC-2, AC-5, AC-6 — it ran out again: the work is set aside, the ticket goes back to the backlog
  # with a note, and nothing starts it again on its own.
  describe "the second time the attempts run out" do
    let!(:open_status) { create(:ticket_status, organization:, position: 0) }
    let!(:in_progress) { create(:ticket_status, :in_progress, organization:, position: 1) }

    before do
      workflow.update!(budget_restart_engine: "codex")
      ticket.update_columns(status_id: in_progress.id)
    end

    it "closes the run and says why" do
      attempt_on("codex")
      stop!

      expect(described_class.call(workflow:)).to be_ok
      expect(workflow.reload.cancelled_at).to be_present
      expect(workflow.cancellation_reason).to include("autopilot")
    end

    it "gives the ticket back to the backlog" do
      attempt_on("codex")
      stop!

      described_class.call(workflow:)

      expect(ticket.reload.status).to eq(open_status)
    end

    it "holds the ticket so nothing starts it again, with the note on why" do
      attempt_on("codex")
      stop!

      described_class.call(workflow:)

      expect(ticket.reload).to have_attributes(agent_eligibility: "blocked",
                                               agent_eligibility_reason: be_present,
                                               agent_eligibility_decided_at: be_present)
    end

    # The source stays on `automatic`: editing the ticket runs the assessment again and may open it,
    # which is what "not until someone changes it" means. A person's own decision is never touched.
    it "leaves the decision open to a later assessment" do
      attempt_on("codex")
      stop!

      described_class.call(workflow:)

      expect(ticket.reload.agent_eligibility_source).to eq("automatic")
    end

    it "leaves a note on the ticket, written by the machine that worked it" do
      attempt = attempt_on("codex")
      stop!

      described_class.call(workflow:)

      comment = ticket.reload.comments.last
      expect(comment.author).to eq(attempt.service_account)
      expect(comment).to be_kind_service
    end

    it "does not start a second run" do
      attempt_on("codex")
      stop!

      described_class.call(workflow:)

      expect(ticket.reload.agent_workflow).to eq(workflow)
    end
  end

  # AC-3, AC-7 — the stops a person owns are decisions, not an exhausted budget.
  describe "stops only a person lifts" do
    %w[safety_stop held_by_person production_approval].each do |kind|
      it "leaves a #{kind} exactly where it is" do
        attempt_on("claude")
        stop!(kind:)

        expect(described_class.call(workflow:).value).to be_nil
        expect(ticket.reload.agent_workflow).to eq(workflow)
        expect(workflow.reload).to have_attributes(blocked_kind: kind, cancelled_at: nil)
      end
    end
  end

  # The length is part of the contract, as for the clarification line: the note is written outside the
  # delivery, so a line over the cap would not break a hand-over — it would just leave the ticket set
  # aside with no note, silently.
  it "keeps the note inside what a comment may hold, in every language" do
    I18n.available_locales.each do |locale|
      line = I18n.t("agents.exhausted_budget.service_line", locale:)
      expect(line.length).to be <= Ticketing::Constants::COMMENT_MAX_CHARS
    end
  end

  # CYRA-1344 — the customer reads the note too: it says the ticket waits for the team, not for them.
  it "tells the reader the ticket waits for the team and they have nothing to do" do
    expect(I18n.t("agents.exhausted_budget.service_line", locale: :it)).to include("aspetta il team", "non devi fare niente")
    expect(I18n.t("agents.exhausted_budget.service_line", locale: :en)).to include("waits for the team", "nothing to do")
  end

  # ── The state the settlement was decided on ───────────────────────────────────────────────────
  #
  # Between the decision and this call a person can press "retry" on that stop, approve the plan the
  # supporter could not, or cancel the run. Without the pin, the work that had just gone back to a
  # machine would be destroyed under its feet.
  describe "a run that moved since the decision" do
    it "leaves alone a stop a person has already lifted" do
      attempt_on("claude")
      stop!
      digest = described_class.state_digest(workflow)
      workflow.update!(**Agents::Workflow.cleared_block)

      expect(described_class.call(workflow:, digest:).value).to be_nil
      expect(ticket.reload.agent_workflow).to eq(workflow)
    end

    it "leaves alone a plan a person has approved meanwhile" do
      attempt_on("claude")
      workflow.update!(triaged_at: 2.minutes.ago, planned_at: 1.minute.ago)
      digest = described_class.state_digest(workflow)
      workflow.update!(approved_at: Time.current)

      expect(described_class.call(workflow:, digest:).value).to be_nil
      expect(ticket.reload.agent_workflow).to eq(workflow)
    end

    it "settles what has not moved" do
      attempt_on("claude")
      stop!

      expect(described_class.call(workflow:, digest: described_class.state_digest(workflow)).value)
        .to eq(:restarted)
    end
  end

  # Half a set-aside — a closed run with no note and nothing holding the ticket — reads exactly like a
  # ticket ready to be picked up again, and the next try would refuse to finish it.
  it "writes the whole set-aside or nothing at all" do
    workflow.update!(budget_restart_engine: "codex")
    attempt_on("codex")
    stop!
    allow(Ticketing::RecordActivity).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "boom")

    expect { described_class.call(workflow:) }.to raise_error(ActiveRecord::StatementInvalid)
    expect(workflow.reload.cancelled_at).to be_nil
    expect(ticket.reload.agent_eligibility).not_to eq("blocked")
  end

  # Those attempts ran out on a RELEASE: the code is written, a person said yes, and the run holds a
  # release number that must outlive even a cancel (CYRA-1031). Starting over would throw the approval
  # away; setting it aside would send back a ticket whose code is already on the main line. Both are
  # left to a person, as before — and the release number's foreign key would refuse the destroy anyway.
  it "leaves an approved delivery to a person, release number and all" do
    repository = create(:github_repository, project:)
    workflow.update!(triaged_at: 5.hours.ago, planned_at: 4.hours.ago, approved_at: 3.hours.ago,
                     autopilot_started_at: 2.hours.ago, autopilot_completed_at: 1.hour.ago,
                     autopilot_approved_at: 30.minutes.ago, closer_staging_started_at: 20.minutes.ago)
    Agents::ReleaseAssignment.create!(workflow:, github_repository: repository,
                                      execution_phase: "closer_staging", version: "v1.2.3-beta.1")
    create(:agent_attempt, organization:, workflow:, phase: "closer_staging", status: :failed, runtime: "claude")
    stop!(phase: "closer_staging")

    expect(described_class.call(workflow:).value).to be_nil
    expect(ticket.reload.agent_workflow).to eq(workflow)
    expect(workflow.reload).to have_attributes(blocked_kind: "attempt_limit", cancelled_at: nil)
  end

  it "does nothing on a run that is already over" do
    workflow.update!(completed_at: Time.current)

    expect(described_class.call(workflow:).value).to be_nil
    expect(ticket.reload.agent_workflow).to eq(workflow)
  end
end
