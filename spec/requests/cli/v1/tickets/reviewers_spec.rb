# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tickets::Reviewers", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, project:, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

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

  describe "PUT reviewer (imposta)" do
    it "owner imposta un revisore membro dell'org → 200" do
      reviewer = org_member
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/reviewer",
          headers: headers, params: { reviewer_id: reviewer.id }

      expect(response).to have_http_status(:ok)
      expect(ticket.reload.reviewer_id).to eq(reviewer.id)
    end

    it "account fuori org → revisore NON impostato (anti-BOLA), 200" do
      outsider = create(:account)
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/reviewer",
          headers: headers, params: { reviewer_id: outsider.id }

      expect(response).to have_http_status(:ok)
      expect(ticket.reload.reviewer_id).not_to eq(outsider.id)
    end

    it "ticket di un'altra org → 404 (anti-BOLA)" do
      other = create(:ticket, organization: create(:organization))
      put "/cli/v1/projects/#{other.project_id}/tickets/#{other.id}/reviewer",
          headers: headers, params: { reviewer_id: account.id }
      expect(response).to have_http_status(:not_found)
    end

    it "membro che vede il progetto ma senza tickets.assign → 403" do
      reviewer = org_member
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/reviewer",
          headers: member_headers, params: { reviewer_id: reviewer.id }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "senza bearer → 401" do
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/reviewer", params: { reviewer_id: account.id }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE reviewer (rimuove)" do
    it "owner rimuove il revisore → 200 + reviewer nil" do
      reviewer = org_member
      ticket.update!(reviewer:)

      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/reviewer", headers: headers

      expect(response).to have_http_status(:ok)
      expect(ticket.reload.reviewer_id).to be_nil
    end

    it "membro che vede il progetto ma senza tickets.assign → 403, revisore invariato" do
      reviewer = org_member
      ticket.update!(reviewer:)

      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/reviewer", headers: member_headers

      expect(response).to have_http_status(:forbidden)
      expect(ticket.reload.reviewer_id).to eq(reviewer.id)
    end

    it "senza bearer → 401" do
      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/reviewer"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
