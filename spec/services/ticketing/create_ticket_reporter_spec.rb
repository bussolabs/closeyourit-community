# frozen_string_literal: true

require "rails_helper"

# CYRA-1086 — who the ticket names as reporter: the person picked in the form, else the project
# owner when the channel asks for it, else whoever creates the ticket.
RSpec.describe Ticketing::CreateTicket, "reporter" do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:status) { create(:ticket_status, organization: org) }
  let(:priority) { create(:ticket_priority, organization: org) }
  let(:creator) { linked_member }
  let(:client) { linked_member }

  def linked_member
    create(:account).tap do |account|
      create(:membership, account: account, organization: org, role: :member)
      create(:project_membership, account: account, project: project)
    end
  end

  def params(extra = {})
    { project_id: project.id, title: "Cart empties on login", description: "Reported by email",
      status_id: status.id, priority_id: priority.id }.merge(extra)
  end

  def create_ticket(extra = {}, use_project_owner: true)
    described_class.call(organization: org, reporter: creator, params: params(extra),
                         use_project_owner: use_project_owner)
  end

  context "when the project has an owner" do
    before { project.update!(owner: client) }

    it "names the owner as reporter and keeps the creator as reviewer and actor" do
      ticket = create_ticket.value

      expect(ticket.reporter).to eq(client)
      expect(ticket.reviewer).to eq(creator)
      event = ticket.events.find_by(action: "created")
      expect(event.actor).to eq(creator)
      expect(event.data["on_behalf_of"]).to eq(client.name)
    end

    it "keeps the creator as reporter when the channel does not ask for the owner" do
      ticket = create_ticket(use_project_owner: false).value

      expect(ticket.reporter).to eq(creator)
      expect(ticket.events.find_by(action: "created").data).not_to have_key("on_behalf_of")
    end

    it "prefers the reporter picked explicitly" do
      other = linked_member

      expect(create_ticket({ reporter_id: other.id }).value.reporter).to eq(other)
    end

    it "falls back to the creator when the owner can no longer see the project" do
      Connections::ProjectMembership.where(account: client, project: project).delete_all

      expect(create_ticket.value.reporter).to eq(creator)
    end
  end

  it "keeps the creator as reporter when the project has no owner" do
    expect(create_ticket.value.reporter).to eq(creator)
  end

  it "refuses an explicit reporter who cannot see the project" do
    outsider = create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }

    result = create_ticket({ reporter_id: outsider.id })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-TICKET-023")
  end

  it "refuses an explicit reporter from another organization" do
    foreign = create(:account).tap { |a| create(:membership, account: a, organization: create(:organization)) }

    expect(create_ticket({ reporter_id: foreign.id })).to be_err
  end
end
