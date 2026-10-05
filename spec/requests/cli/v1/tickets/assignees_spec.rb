# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tickets::Assignees", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, project:, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  # Candidato assegnatario: membro dell'org (l'isolamento tenant è validato sul model).
  def org_member
    create(:account).tap { |member| create(:membership, account: member, organization:, role: :member) }
  end

  # Membro che VEDE il progetto ma senza tickets.assign → testa il 403.
  def member_headers
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project:)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{member_secret}" }
  end

  describe "PUT assignee (assegna)" do
    it "owner assegna a un membro dell'org → 200" do
      assignee = org_member
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/assignee",
          headers: headers, params: { assignee_id: assignee.id }

      expect(response).to have_http_status(:ok)
      expect(ticket.reload.assignee_id).to eq(assignee.id)
    end

    it "account fuori org → resta non assegnato (anti-BOLA), 200" do
      outsider = create(:account) # nessuna membership nell'org
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/assignee",
          headers: headers, params: { assignee_id: outsider.id }

      expect(response).to have_http_status(:ok)
      expect(ticket.reload.assignee_id).to be_nil
    end

    it "ticket di un'altra org → 404 (anti-BOLA)" do
      other = create(:ticket, organization: create(:organization))
      put "/cli/v1/projects/#{other.project_id}/tickets/#{other.id}/assignee",
          headers: headers, params: { assignee_id: account.id }
      expect(response).to have_http_status(:not_found)
    end

    it "membro che vede il progetto ma senza tickets.assign → 403" do
      assignee = org_member
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/assignee",
          headers: member_headers, params: { assignee_id: assignee.id }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
      expect(ticket.reload.assignee_id).to be_nil
    end

    it "senza bearer → 401" do
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/assignee", params: { assignee_id: account.id }
      expect(response).to have_http_status(:unauthorized)
    end

    it "AssignTicket fallisce → render_error con codice/status/dettagli del Result" do
      assignee = org_member
      allow(Ticketing::AssignTicket).to receive(:call).and_return(
        Result.err(AppError.new("assegnazione fallita", code: "R422-TICKET-002",
                                status: :unprocessable_content, details: { assignee: [ "non valido" ] }))
      )

      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/assignee",
          headers: headers, params: { assignee_id: assignee.id }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-TICKET-002")
    end
  end

  describe "DELETE assignee (disassegna)" do
    it "owner disassegna → 200 + assignee nil" do
      assignee = org_member
      ticket.update!(assignee:)

      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/assignee", headers: headers

      expect(response).to have_http_status(:ok)
      expect(ticket.reload.assignee_id).to be_nil
    end

    it "ticket di un'altra org → 404 (anti-BOLA)" do
      other = create(:ticket, organization: create(:organization))
      delete "/cli/v1/projects/#{other.project_id}/tickets/#{other.id}/assignee", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "membro che vede il progetto ma senza tickets.assign → 403, assegnazione invariata" do
      assignee = org_member
      ticket.update!(assignee:)

      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/assignee", headers: member_headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
      expect(ticket.reload.assignee_id).to eq(assignee.id)
    end

    it "senza bearer → 401" do
      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/assignee"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
