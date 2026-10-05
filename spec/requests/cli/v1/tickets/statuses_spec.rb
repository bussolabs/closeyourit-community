# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tickets::Statuses", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, project:, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  # Membro che VEDE il progetto ma senza tickets.edit → testa il 403.
  def member_headers
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project:)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{member_secret}" }
  end

  describe "PUT status" do
    it "owner cambia lo status → 200 + label nuova" do
      new_status = create(:ticket_status, organization:, label: "In review")
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/status",
          headers: headers, params: { status_id: new_status.id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["status"]).to eq("In review")
      expect(ticket.reload.status_id).to eq(new_status.id)
    end

    it "status di un'altra org → 422 R422-TICKET-003 (anti-BOLA), status invariato" do
      original = ticket.status_id
      foreign = create(:ticket_status) # altra org
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/status",
          headers: headers, params: { status_id: foreign.id }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-TICKET-003")
      expect(ticket.reload.status_id).to eq(original)
    end

    it "ticket di un'altra org → 404 (anti-BOLA)" do
      other = create(:ticket, organization: create(:organization))
      put "/cli/v1/projects/#{other.project_id}/tickets/#{other.id}/status",
          headers: headers, params: { status_id: create(:ticket_status, organization:).id }
      expect(response).to have_http_status(:not_found)
    end

    it "membro che vede il progetto ma senza tickets.edit → 403" do
      new_status = create(:ticket_status, organization:)
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/status",
          headers: member_headers, params: { status_id: new_status.id }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "senza bearer → 401" do
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/status", params: { status_id: ticket.status_id }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
