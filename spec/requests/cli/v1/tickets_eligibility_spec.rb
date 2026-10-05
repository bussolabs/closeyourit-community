# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tickets — eleggibilità agenti", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "DRFL") }
  let(:owner) do
    create(:account).tap { |account| create(:membership, account:, organization:, role: :owner) }
  end
  let(:token) { Accounts::ApiTokens::Issue.call(account: owner, organization:, name: "cli").value }
  let(:headers) { { "Authorization" => "Bearer #{token.fetch(:secret)}" } }
  let(:ticket) { create(:ticket, :agent_blocked, organization:, project:) }

  describe "lettura" do
    it "espone verdetto, motivazione, sorgente e istante della decisione" do
      get "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}", headers: headers

      data = response.parsed_body.fetch("data")
      expect(data).to include("agent_eligibility" => "blocked", "agent_eligibility_source" => "human")
      expect(data.fetch("agent_eligibility_reason")).to be_present
    end

    it "filtra la lista per eleggibilità" do
      workable = create(:ticket, :agent_workable, organization:, project:)

      get "/cli/v1/projects/#{project.id}/tickets", params: { agent_eligibility: "allowed" }, headers: headers

      codes = response.parsed_body.fetch("data").map { |t| t.fetch("code") }
      expect(codes).to include(workable.code)
      expect(codes).not_to include(ticket.code)
    end
  end

  describe "override" do
    it "consente un ticket bloccato e lo restituisce aggiornato" do
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.code}/eligibility",
          params: { eligibility: "allowed", reason: "Verificato a mano." }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "agent_eligibility")).to eq("allowed")
      expect(ticket.reload).to have_attributes(agent_eligibility: "allowed", agent_eligibility_source: "human")
    end

    it "riporta alla valutazione automatica e ne richiede una nuova" do
      Ticketing::SetAgentEligibility.call(ticket:, source: :human, eligibility: "allowed",
                                          reason: "sicuro", actor: owner)

      expect do
        put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/eligibility",
            params: { eligibility: "auto" }, headers: headers, as: :json
      end.to have_enqueued_job(Ticketing::EvaluateAgentEligibilityJob).with(ticket_id: ticket.id)

      expect(ticket.reload).to be_agent_eligibility_pending
    end

    it "rifiuta un valore non previsto" do
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/eligibility",
          params: { eligibility: "forse" }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-TICKET-014")
    end

    it "nega a chi non può modificare il ticket" do
      member = create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
      create(:project_membership, account: member, project:)
      member_token = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "cli").value

      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/eligibility",
          params: { eligibility: "allowed" },
          headers: { "Authorization" => "Bearer #{member_token.fetch(:secret)}" }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(ticket.reload.agent_eligibility).to eq("blocked")
    end
  end
end
