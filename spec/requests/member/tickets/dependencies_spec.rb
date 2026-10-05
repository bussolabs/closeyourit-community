# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Tickets — dipendenze", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:open_status) { create(:ticket_status, organization: org, code: "open", label: "Open") }
  let(:ticket) { create(:ticket, organization: org, project: project, status: open_status) }
  let(:blocker) { create(:ticket, organization: org, project: project, status: open_status) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # Anti-BOLA in lettura: un blocker cross-project (ammesso dal model) può stare in un progetto che
  # chi guarda A non vede — code/title non devono trapelare (leak intra-org). `member` è scoped su
  # `project`, quindi un blocker in un altro progetto gli è invisibile.
  describe "GET /member/tickets/:id — blocker cross-project non visibile" do
    it "oscura il blocker fuori scope: placeholder, niente code/title/link" do
      hidden_project = create(:project, organization: org)
      hidden_blocker = create(:ticket, organization: org, project: hidden_project, status: open_status, title: "Segreto di un altro progetto")
      dependency = create(:ticket_dependency, ticket: ticket, blocker: hidden_blocker)
      sign_in(member)

      get member_ticket_path(ticket)

      expect(response.body).to include("data-test=\"dependency-hidden-#{dependency.id}\"")
      expect(response.body).not_to include(hidden_blocker.code)
      expect(response.body).not_to include("Segreto di un altro progetto")
      expect(response.body).not_to include("data-test=\"dependency-target-#{hidden_blocker.id}\"")
    end

    it "un blocker visibile resta mostrato per intero (code/title/link)" do
      create(:ticket_dependency, ticket: ticket, blocker: blocker)
      sign_in(member)

      get member_ticket_path(ticket)

      expect(response.body).to include("data-test=\"dependency-target-#{blocker.id}\"")
      expect(response.body).to include(blocker.code)
    end
  end

  describe "POST /member/tickets/:ticket_id/dependencies" do
    it "con tickets.edit aggiunge il prerequisito e reindirizza con notice + evento in timeline" do
      sign_in(owner)

      expect { post member_ticket_dependencies_path(ticket), params: { blocker_id: blocker.id } }
        .to change(Connections::TicketDependency, :count).by(1)

      expect(response).to redirect_to(member_ticket_path(ticket))
      expect(flash[:notice]).to eq(I18n.t("member.tickets.dependencies.added"))
      expect(ticket.events.where(action: "dependency_added")).to exist
    end

    # Scenario 4: nascondere la UI non basta — la POST è respinta server-side (redirect a root).
    it "senza tickets.edit non aggiunge (403 reale: redirect a root)" do
      sign_in(member)

      expect { post member_ticket_dependencies_path(ticket), params: { blocker_id: blocker.id } }
        .not_to change(Connections::TicketDependency, :count)

      expect(response).to redirect_to(root_path)
    end

    # Scenario 5: un blocker non visibile (altra org) è respinto, nessuna dipendenza.
    it "blocker cross-tenant non visibile → non aggiunge, alert" do
      other_org = create(:organization)
      foreign = create(:ticket, organization: other_org, project: create(:project, organization: other_org))
      sign_in(owner)

      expect { post member_ticket_dependencies_path(ticket), params: { blocker_id: foreign.id } }
        .not_to change(Connections::TicketDependency, :count)

      expect(response).to redirect_to(member_ticket_path(ticket))
      expect(flash[:alert]).to be_present
    end

    it "cross-project intra-org è ammesso" do
      cross = create(:ticket, organization: org, project: create(:project, organization: org), status: open_status)
      sign_in(owner)

      expect { post member_ticket_dependencies_path(ticket), params: { blocker_id: cross.id } }
        .to change(Connections::TicketDependency, :count).by(1)
    end

    it "duplicato → nessun doppione, alert" do
      create(:ticket_dependency, ticket: ticket, blocker: blocker)
      sign_in(owner)

      expect { post member_ticket_dependencies_path(ticket), params: { blocker_id: blocker.id } }
        .not_to change(Connections::TicketDependency, :count)

      expect(flash[:alert]).to be_present
    end

    it "ciclo → non crea, alert col messaggio del ciclo (422 mostrato in UI)" do
      create(:ticket_dependency, ticket: blocker, blocker: ticket)
      sign_in(owner)

      post member_ticket_dependencies_path(ticket), params: { blocker_id: blocker.id }

      expect(flash[:alert]).to eq(I18n.t("member.tickets.dependencies.errors.cycle"))
    end
  end

  describe "DELETE /member/tickets/:ticket_id/dependencies/:id" do
    let!(:dependency) { create(:ticket_dependency, ticket: ticket, blocker: blocker) }

    it "con tickets.edit rimuove e reindirizza con notice" do
      sign_in(owner)

      expect { delete member_ticket_dependency_path(ticket, dependency) }
        .to change(Connections::TicketDependency, :count).by(-1)

      expect(response).to redirect_to(member_ticket_path(ticket))
      expect(flash[:notice]).to eq(I18n.t("member.tickets.dependencies.removed"))
    end

    it "senza tickets.edit non rimuove (403 reale: redirect a root)" do
      sign_in(member)

      expect { delete member_ticket_dependency_path(ticket, dependency) }
        .not_to change(Connections::TicketDependency, :count)

      expect(response).to redirect_to(root_path)
    end

    # Scenario 2: rimozione idempotente — una seconda DELETE dà un 404 chiaro, non un 500.
    it "id inesistente → alert not_found (non 500)" do
      sign_in(owner)

      delete member_ticket_dependency_path(ticket, SecureRandom.uuid)

      expect(response).to redirect_to(member_ticket_path(ticket))
      expect(flash[:alert]).to eq(I18n.t("member.tickets.dependencies.errors.not_found"))
    end

    it "anti-BOLA: una dependency di un altro ticket non è rimovibile da questa show" do
      other_ticket = create(:ticket, organization: org, project: project, status: open_status)
      foreign = create(:ticket_dependency, ticket: other_ticket, blocker: blocker)
      sign_in(owner)

      expect { delete member_ticket_dependency_path(ticket, foreign) }
        .not_to change(Connections::TicketDependency, :count)
    end
  end
end
