# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member ticket epics", type: :request do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:owner) { create(:account) }
  let(:status) { create(:ticket_status, organization: org) }
  let(:priority) { create(:ticket_priority, organization: org) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "form" do
    it "offre il select dell'epic con gli epic del progetto" do
      epic = create(:ticket, :epic, organization: org, project: project, title: "Checkout nuovo")
      sign_in(owner)
      get new_member_ticket_path

      expect(response.body).to include('data-test="ticket-parent-field"')
      expect(response.body).to include(epic.code)
    end

    it "in modifica non offre il ticket stesso come proprio padre" do
      epic = create(:ticket, :epic, organization: org, project: project, status: status, priority: priority)
      sign_in(owner)
      get edit_member_ticket_path(epic)

      expect(response.body).to include('data-test="ticket-parent-field"')
      expect(response.body).not_to include(%(value="#{epic.id}"))
    end
  end

  describe "show" do
    it "sull'epic elenca i figli col conteggio dei chiusi" do
      done = create(:ticket_status, :done, organization: org)
      epic = create(:ticket, :epic, organization: org, project: project, status: status, priority: priority)
      open_child = create(:ticket, :story, organization: org, project: project, parent: epic,
                                           status: status, priority: priority)
      closed_child = create(:ticket, :task, organization: org, project: project, parent: epic,
                                            status: done, priority: priority)

      sign_in(owner)
      get member_ticket_path(epic)

      expect(response.body).to include('data-test="ticket-children"')
      expect(response.body).to include("ticket-child-#{open_child.id}", "ticket-child-#{closed_child.id}")
      expect(response.body).to include("1/2")
    end

    it "su un epic vuoto la card resta con lo stato vuoto" do
      epic = create(:ticket, :epic, organization: org, project: project, status: status, priority: priority)
      sign_in(owner)
      get member_ticket_path(epic)

      expect(response.body).to include('data-test="ticket-children-empty"')
    end

    it "su un ticket qualsiasi la card dei figli non compare" do
      story = create(:ticket, :story, organization: org, project: project, status: status, priority: priority)
      sign_in(owner)
      get member_ticket_path(story)

      expect(response.body).not_to include('data-test="ticket-children"')
    end

    it "su un figlio mostra il link all'epic padre" do
      epic = create(:ticket, :epic, organization: org, project: project, status: status, priority: priority)
      child = create(:ticket, :story, organization: org, project: project, parent: epic,
                                      status: status, priority: priority)

      sign_in(owner)
      get member_ticket_path(child)

      expect(response.body).to include('data-test="ticket-parent-link"')
      expect(response.body).to include(epic.code)
    end
  end

  describe "create/update dal web" do
    it "aggancia il ticket all'epic scelto nel form" do
      epic = create(:ticket, :epic, organization: org, project: project, status: status, priority: priority)
      sign_in(owner)

      post member_tickets_path, params: {
        project_id: project.id, title: "Pagamento con carta", description: "Serve pagare con carta",
        kind: "story", status_id: status.id, priority_id: priority.id, parent_id: epic.id
      }

      expect(Ticketing::Ticket.find_by(title: "Pagamento con carta").parent).to eq(epic)
    end

    it "un epic di un altro progetto non viene agganciato (anti-BOLA, resta senza padre)" do
      foreign_epic = create(:ticket, :epic, organization: org, project: create(:project, organization: org),
                                            status: status, priority: priority)
      sign_in(owner)

      post member_tickets_path, params: {
        project_id: project.id, title: "Ticket senza epic", description: "corpo",
        kind: "story", status_id: status.id, priority_id: priority.id, parent_id: foreign_epic.id
      }

      expect(Ticketing::Ticket.find_by(title: "Ticket senza epic").parent).to be_nil
    end
  end
end
