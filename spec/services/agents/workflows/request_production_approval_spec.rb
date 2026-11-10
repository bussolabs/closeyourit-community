# frozen_string_literal: true

require "rails_helper"

# CYRA-1278 — where a project or its group asks for it, production waits for a person's go-ahead.
RSpec.describe Agents::Workflows::RequestProductionApproval do
  let(:organization) { create(:organization) }
  let(:group) { create(:group, organization:) }
  let(:project) { create(:project, organization:, group:, key: "CYAU") }
  let!(:repository) { create(:github_repository, project:) }
  let(:cto) do
    create(:account).tap do |account|
      create(:membership, account:, organization:)
      create(:project_membership, account:, project:)
    end
  end

  before do
    organization.update!(cto:)
    versioni_uscite("v1.0.0")
  end

  def waiting_for_production(target: project)
    ticket = create(:ticket, :agent_workable, organization:, project: target, with_agent_workflow: true)
    workflow = pronta_per!(ticket.agent_workflow, "closer_production")
    workflow.update!(closer_production_approved_at: nil)
    create(:agent_attempt, workflow:, organization:, phase: "closer_staging", status: :approved,
                           result: { "code" => ticket.code, "state" => "staging-released",
                                     "tag" => "v1.0.0-beta.1", "commit" => "a" * 40 })
    workflow
  end

  def ready_host
    service_account = Accounts::Service::Create.call(organization:, name: "Host SA #{SecureRandom.hex(3)}",
                                                     project_ids: [ project.id ]).value
    create(:agent_host, organization:, service_account:, last_heartbeat_at: Time.current,
                        repositories: [ project.key ], runtimes: [ { "name" => "claude", "present" => true } ])
  end

  def queue_head = Agents::TicketQueues::Candidates.new(project:, host: ready_host).head_id

  describe ".call" do
    it "stops the work before production when the project asks for a go-ahead" do
      project.update!(production_approval_required: true)
      workflow = waiting_for_production

      described_class.call(workflow:)

      expect(workflow.reload).to have_attributes(blocked_phase: "closer_production",
                                                 blocked_kind: "production_approval")
      expect(workflow.ready_execution_phase).to be_nil
    end

    it "stops the work when only the group asks for a go-ahead" do
      group.update!(production_approval_required: true)
      workflow = waiting_for_production

      described_class.call(workflow:)

      expect(workflow.reload.blocked_kind).to eq("production_approval")
    end

    it "leaves the work alone when neither the project nor the group asks" do
      workflow = waiting_for_production

      described_class.call(workflow:)

      expect(workflow.reload.blocked_at).to be_nil
      expect(workflow.ready_execution_phase).to eq("closer_production")
    end

    it "leaves the work alone once a person gave the go-ahead" do
      project.update!(production_approval_required: true)
      workflow = waiting_for_production
      workflow.update!(closer_production_approved_at: Time.current, closer_production_approved_by: cto)

      described_class.call(workflow:)

      expect(workflow.reload.blocked_at).to be_nil
    end

    it "leaves the work alone before the staging check is closed" do
      project.update!(production_approval_required: true)
      ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
      workflow = pronta_per!(ticket.agent_workflow, "closer_staging")

      described_class.call(workflow:)

      expect(workflow.reload.blocked_at).to be_nil
    end
  end

  describe ".for_projects" do
    it "stops the work already waiting for production when the switch is turned on" do
      waiting = waiting_for_production
      other_project = create(:project, organization:)
      create(:github_repository, project: other_project)
      untouched = waiting_for_production(target: other_project)
      project.update!(production_approval_required: true)

      described_class.for_projects(Projects::Project.where(id: project.id))

      expect(waiting.reload.blocked_kind).to eq("production_approval")
      expect(untouched.reload.blocked_at).to be_nil
    end
  end

  describe "the go-ahead" do
    it "records who gave it and puts the release back in the queue" do
      project.update!(production_approval_required: true)
      workflow = waiting_for_production
      described_class.call(workflow:)

      expect(Agents::Workflows::Unblock.call(workflow:, actor: cto)).to be_ok

      expect(workflow.reload).to have_attributes(blocked_at: nil, closer_production_approved_by: cto)
      expect(workflow.closer_production_approved_at).to be_present
      expect(workflow.ready_execution_phase).to eq("closer_production")
      expect(queue_head).to eq(workflow.ticket_id)
    end

    it "is asked again when a different stop is lifted and the go-ahead is still missing" do
      project.update!(production_approval_required: true)
      workflow = waiting_for_production
      Agents::Workflows::HoldProduction.call(workflow:, actor: cto)

      Agents::Workflows::Unblock.call(workflow:, actor: cto)

      expect(workflow.reload.blocked_kind).to eq("production_approval")
      expect(workflow.closer_production_approved_at).to be_nil
    end
  end

  describe "the hold before production" do
    it "keeps the release out of the queue while the go-ahead is missing, even with no block written" do
      project.update!(production_approval_required: true)
      workflow = waiting_for_production

      expect(queue_head).to be_nil
      expect(Agents::Workflows::ProductionHold.reason(workflow, now: Time.current))
        .to eq(reason: "production_approval")
    end

    it "does not hold a project that never asked for a go-ahead" do
      workflow = waiting_for_production

      expect(queue_head).to eq(workflow.ticket_id)
      expect(Agents::Workflows::ProductionHold.reason(workflow, now: Time.current)).to be_nil
    end
  end
end
