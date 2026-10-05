# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workload::Actions::PromoteToTicket, type: :service do
  let(:organization) { create(:organization) }
  let(:team) { create(:team, organization: organization) }
  let(:project) { create(:project, organization: organization) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) }
  end
  let(:action) { create(:workload_action, team: team, organization: organization, title: "Riunione firma accordo") }

  before { Types::InstallDefaults.call(organization: organization) }

  it "genera il ticket nel progetto scelto e salva il backlink" do
    result = described_class.call(action: action, reporter: owner,
                                  params: { project_id: project.id, description: "Implementazione API servizio esterno" })

    expect(result).to be_ok
    ticket = result.value
    expect(ticket.project).to eq(project)
    expect(ticket.title).to eq("Riunione firma accordo")
    expect(ticket.description).to eq("Implementazione API servizio esterno")
    expect(action.reload.ticket).to eq(ticket)
  end

  it "default: kind task, status open, priority medium" do
    ticket = described_class.call(action: action, reporter: owner,
                                  params: { project_id: project.id, description: "x" }).value

    expect(ticket).to be_kind_task
    expect(ticket.status.code).to eq("open")
    expect(ticket.priority.code).to eq("medium")
  end

  it "kind esplicito: vince sul default" do
    ticket = described_class.call(action: action, reporter: owner,
                                  params: { project_id: project.id, description: "x", kind: "bug" }).value

    expect(ticket).to be_kind_bug
  end

  it "action già linkata → R422-WORKLOAD-003, nessun secondo ticket" do
    linked = create(:workload_action, :with_ticket, team: team, organization: organization)

    expect do
      result = described_class.call(action: linked, reporter: owner, params: { project_id: project.id })
      expect(result).to be_err
      expect(result.error.code).to eq("R422-WORKLOAD-003")
    end.not_to change(Ticketing::Ticket, :count)
  end

  it "progetto non visibile al reporter → R404-WORKLOAD-001, action non linkata" do
    member = create(:account).tap { |a| create(:team_membership, team: team, account: a) }

    result = described_class.call(action: action, reporter: member,
                                  params: { project_id: project.id, description: "x" })

    expect(result).to be_err
    expect(result.error.code).to eq("R404-WORKLOAD-001")
    expect(action.reload.ticket).to be_nil
  end

  it "progetto di un'altra organizzazione → R404-WORKLOAD-001" do
    other_org = create(:organization)
    other_project = create(:project, organization: other_org)

    result = described_class.call(action: action, reporter: owner, params: { project_id: other_project.id })

    expect(result).to be_err
    expect(result.error.code).to eq("R404-WORKLOAD-001")
  end
end
