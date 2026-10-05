# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tickets::Milestones", type: :request do
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

  describe "PUT milestone (imposta)" do
    it "owner imposta una milestone del progetto → 200" do
      milestone = create(:milestone, project:)
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/milestone",
          headers: headers, params: { milestone_id: milestone.id }

      expect(response).to have_http_status(:ok)
      expect(ticket.reload.milestone_id).to eq(milestone.id)
    end

    it "milestone di un altro progetto → 422 R422-TICKET-004 (anti-BOLA)" do
      foreign = create(:milestone) # milestone di un progetto diverso
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/milestone",
          headers: headers, params: { milestone_id: foreign.id }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-TICKET-004")
      expect(ticket.reload.milestone_id).to be_nil
    end

    it "ticket di un'altra org → 404 (anti-BOLA)" do
      other = create(:ticket, organization: create(:organization))
      put "/cli/v1/projects/#{other.project_id}/tickets/#{other.id}/milestone",
          headers: headers, params: { milestone_id: create(:milestone, project: other.project).id }
      expect(response).to have_http_status(:not_found)
    end

    it "membro che vede il progetto ma senza tickets.edit → 403" do
      milestone = create(:milestone, project:)
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/milestone",
          headers: member_headers, params: { milestone_id: milestone.id }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "senza bearer → 401" do
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/milestone", params: { milestone_id: "x" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE milestone (rimuove)" do
    it "owner rimuove la milestone → 200 + milestone nil" do
      milestone = create(:milestone, project:)
      ticket.update!(milestone:)

      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/milestone", headers: headers

      expect(response).to have_http_status(:ok)
      expect(ticket.reload.milestone_id).to be_nil
    end

    it "ticket di un'altra org → 404 (anti-BOLA)" do
      other = create(:ticket, organization: create(:organization))
      delete "/cli/v1/projects/#{other.project_id}/tickets/#{other.id}/milestone", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "membro che vede il progetto ma senza tickets.edit → 403, milestone invariata" do
      milestone = create(:milestone, project:)
      ticket.update!(milestone:)

      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/milestone", headers: member_headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
      expect(ticket.reload.milestone_id).to eq(milestone.id)
    end

    it "senza bearer → 401" do
      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/milestone"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
