# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Moves::Plan do
  let(:source) { create(:organization) }
  let(:destination) { create(:organization) }
  let(:project) { create(:project, organization: source, key: "MOVE") }

  def report = described_class.call(subject: Projects::Moves::Subject.new(project), destination:).value
  def codes = report.blockers.map { _1[:code] }

  def source_member
    create(:membership, organization: source).account
  end

  it "is clean for a bare project" do
    expect(report).not_to be_blocked
  end

  it "blocks when the destination already uses the key" do
    create(:project, organization: destination, key: "MOVE")
    expect(codes).to include("key_taken")
  end

  it "blocks when an active person is not a member of the destination" do
    cto = source_member
    project.update_columns(cto_id: cto.id)
    expect(report.blockers).to include(a_hash_including(code: "person_not_member", detail: a_string_including(cto.email)))
  end

  it "does not block once the person is a member of the destination" do
    cto = source_member
    project.update_columns(cto_id: cto.id)
    create(:membership, account: cto, organization: destination)
    expect(codes).not_to include("person_not_member")
  end

  it "ignores the assignee of a done ticket" do
    assignee = source_member
    done = create(:ticket_status, organization: source, category: :done)
    create(:ticket, project:, status: done).update_columns(assignee_id: assignee.id)

    expect(codes).not_to include("person_not_member")
  end

  it "blocks on the assignee of an open ticket" do
    assignee = source_member
    create(:ticket, project:).update_columns(assignee_id: assignee.id)

    expect(report.blockers).to include(a_hash_including(code: "person_not_member", detail: a_string_including(assignee.email)))
  end

  it "blocks on the default assignee" do
    person = source_member
    project.update_columns(default_assignee_id: person.id)
    expect(report.blockers).to include(a_hash_including(code: "person_not_member", detail: a_string_including(person.email)))
  end

  it "blocks on the reviewer of an open ticket" do
    person = source_member
    create(:ticket, project:).update_columns(reviewer_id: person.id)
    expect(report.blockers).to include(a_hash_including(code: "person_not_member", detail: a_string_including(person.email)))
  end

  it "blocks on the assignee of an error group" do
    person = source_member
    create(:error_group, project:).update_columns(assignee_id: person.id)
    expect(report.blockers).to include(a_hash_including(code: "person_not_member", detail: a_string_including(person.email)))
  end

  it "blocks on a person with secret access to the project" do
    person = source_member
    create(:account_secret_access, account: person, project:)
    expect(report.blockers).to include(a_hash_including(code: "person_not_member", detail: a_string_including(person.email)))
  end

  it "blocks on the owner of a secret override" do
    override = create(:secret_override, project:)
    expect(report.blockers).to include(a_hash_including(code: "person_not_member", detail: a_string_including(override.account.email)))
  end

  it "blocks on a member of a moved group" do
    group = create(:group, organization: source)
    membership = create(:group_membership, group:)
    group_report = described_class.call(subject: Projects::Moves::Subject.new(group), destination:).value

    expect(group_report.blockers)
      .to include(a_hash_including(code: "person_not_member", detail: a_string_including(membership.account.email)))
  end

  it "blocks when a provision links to a project that stays behind" do
    env = create(:environment, organization: source)
    other = create(:project, organization: source)
    project.environments << env
    other.environments << env
    create(:secret_provision, organization: source, source_project: project, destination_project: other,
                              source_environment: env, destination_environment: env)
    expect(codes).to include("provision_crosses")
  end

  it "blocks while an agent holds a ticket of the project" do
    ticket = create(:ticket, project:)
    create(:agent_lease, ticket:, organization: source, host: create(:agent_host, organization: source))
    expect(report.blockers).to include({ code: "agent_running", detail: ticket.code })
  end

  it "ignores an expired lease" do
    ticket = create(:ticket, project:)
    create(:agent_lease, ticket:, organization: source, host: create(:agent_host, organization: source))
      .update_columns(expires_at: 1.minute.ago)
    expect(codes).not_to include("agent_running")
  end

  it "blocks while an agent workflow of a ticket is open" do
    create(:ticket, project:, with_agent_workflow: true)
    expect(codes).to include("agent_running")
  end

  it "ignores an open agent workflow untouched for longer than the stale window" do
    ticket = create(:ticket, project:, with_agent_workflow: true)
    ticket.agent_workflow.update_columns(updated_at: (Projects::Move::STALE_AFTER + 1.minute).ago)
    expect(codes).not_to include("agent_running")
  end

  it "ignores a blocked agent workflow even when it was updated recently" do
    ticket = create(:ticket, project:, with_agent_workflow: true)
    ticket.agent_workflow.update_columns(blocked_at: Time.current, blocked_kind: "agent_blocked", updated_at: Time.current)
    expect(codes).not_to include("agent_running")
  end

  describe "live automation on an idle workflow" do
    let(:workflow) do
      create(:ticket, project:, with_agent_workflow: true).agent_workflow.tap do |workflow|
        workflow.update_columns(updated_at: 1.day.ago)
      end
    end

    it "blocks while a release probe is open and within its window" do
      workflow.probes.create!(kind: "deploy_smoke", bound_at: 10.minutes.ago, next_check_at: 1.minute.from_now)
      expect(codes).to include("agent_running")
    end

    it "ignores an open probe past its window on a blocked workflow" do
      workflow.update_columns(blocked_at: 1.day.ago, blocked_kind: "release_probe")
      workflow.probes.create!(kind: "deploy_smoke", bound_at: 3.days.ago, next_check_at: 3.days.ago)
      expect(codes).not_to include("agent_running")
    end

    it "ignores an open probe past its window on an open workflow" do
      workflow.probes.create!(kind: "deploy_smoke", bound_at: (Agents::WorkflowProbe::GRACE_WINDOW + 1.minute).ago)
      expect(codes).not_to include("agent_running")
    end

    it "ignores an open probe on a cancelled workflow" do
      workflow.update_columns(cancelled_at: 1.hour.ago)
      workflow.probes.create!(kind: "deploy_smoke", bound_at: 10.minutes.ago, next_check_at: 1.minute.from_now)
      expect(codes).not_to include("agent_running")
    end

    it "ignores a delivery candidate awaiting a check on a completed workflow" do
      workflow.update_columns(completed_at: 1.hour.ago)
      create(:agent_delivery_candidate, :unreachable, workflow:, organization: source)
      expect(codes).not_to include("agent_running")
    end

    it "ignores a closed release probe" do
      workflow.probes.create!(kind: "deploy_smoke", bound_at: 1.day.ago, closed_at: 1.hour.ago)
      expect(codes).not_to include("agent_running")
    end

    it "blocks while a delivery candidate awaits its next check" do
      create(:agent_delivery_candidate, :unreachable, workflow:, organization: source)
      expect(codes).to include("agent_running")
    end

    it "ignores a delivery candidate with no check scheduled" do
      create(:agent_delivery_candidate, :rejected, workflow:, organization: source)
      expect(codes).not_to include("agent_running")
    end
  end

  it "blocks while another move of the same subject is active" do
    create(:project_move, subject: project, destination_organization: destination)
    expect(codes).to include("move_in_progress")
  end

  it "ignores the move it is planned for" do
    move = create(:project_move, subject: project, destination_organization: destination, status: :running)
    planned = described_class.call(subject: Projects::Moves::Subject.new(project), destination:, move:).value
    expect(planned.blockers.map { _1[:code] }).not_to include("move_in_progress")
  end

  it "blocks a group while one of its projects is being moved" do
    group = create(:group, organization: source)
    project.update_columns(group_id: group.id)
    create(:project_move, subject: project, destination_organization: destination)
    group_report = described_class.call(subject: Projects::Moves::Subject.new(group), destination:).value

    expect(group_report.blockers.map { _1[:code] }).to include("move_in_progress")
  end

  it "blocks a project while its group is being moved" do
    group = create(:group, organization: source)
    project.update_columns(group_id: group.id)
    create(:project_move, subject: group, destination_organization: destination)

    expect(codes).to include("move_in_progress")
  end

  describe "the premises Execute checks again under its locks" do
    let(:owner) { create(:account) }
    let!(:move) do
      create(:project_move, subject: project, destination_organization: destination, requested_by: owner, status: :running)
    end

    def planned_codes
      described_class.call(subject: Projects::Moves::Subject.new(project.reload), destination:, move:).value
                     .blockers.map { _1[:code] }
    end

    before do
      create(:membership, account: owner, organization: source, role: :owner)
      create(:membership, account: owner, organization: destination, role: :owner)
    end

    it "holds while the requester owns both organizations and the subject is still in the source" do
      expect(planned_codes).to be_empty
    end

    it "blocks when the subject has left the source organization" do
      project.update_columns(organization_id: create(:organization).id)
      expect(planned_codes).to include("subject_left_source")
    end

    it "blocks when the requester no longer owns one of the organizations" do
      Connections::Membership.find_by!(account: owner, organization: destination).update_columns(role: :admin)
      expect(planned_codes).to include("requester_not_owner")
    end

    it "is not checked for a preview, which has no move yet" do
      Connections::Membership.find_by!(account: owner, organization: destination).update_columns(role: :admin)
      expect(codes).not_to include("requester_not_owner")
    end
  end

  it "blocks on a shared value that differs in the destination, without its value" do
    env = create(:environment, organization: source, code: "production")
    project.environments << env
    value = Secrets::Shared::Variable.create!(organization: source, name: "DATABASE_URL")
                                     .values.create!(environment: env, value: "postgres://one")
    Secrets::Shared::Delegation.create!(shared_value: value, project:)
    Secrets::Shared::Variable.create!(organization: destination, name: "DATABASE_URL")
                             .values.create!(environment: create(:environment, organization: destination, code: "production"),
                                             value: "postgres://two")

    expect(report.blockers).to include({ code: "shared_conflict", detail: "variable DATABASE_URL (production)" })
    expect(report.to_h.to_s).not_to include("postgres://")
  end

  it "lists environments to create and links to detach" do
    env = create(:environment, organization: source, code: "qa")
    project.environments << env
    create(:alerting_rule, :scoped, organization: source, project:)
    create(:github_repository, project:)

    expect(report.creations).to include(a_hash_including(table: "types_environments", code: "qa"))
    expect(report.detachments).to include({ table: "alerting_rules", count: 1 },
                                          { table: "github_repositories", count: 1 })
  end

  it "lists the group link a project moved alone leaves behind" do
    project.update!(group: create(:group, organization: source))
    expect(report.detachments).to include({ table: "projects_groups", count: 1 })
  end

  it "keeps the group link when the whole group moves" do
    group = create(:group, organization: source)
    project.update!(group:)
    group_report = described_class.call(subject: Projects::Moves::Subject.new(group), destination:).value

    expect(group_report.detachments.pluck(:table)).not_to include("projects_groups")
  end

  it "serializes to a hash for the move record" do
    expect(report.to_h).to eq(blockers: [], creations: report.creations, detachments: [])
  end
end
