# frozen_string_literal: true

require "rails_helper"

# Accesso d'audit allo snapshot immutabile della Guidance consegnata alla presa in carico (CYRA-76),
# gated dalla chiave dedicata tickets.audit.view.
RSpec.describe "Cli::V1::Tickets::WorkContext", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, project:, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  # Membro che VEDE il progetto (project_membership) ma senza tickets.audit.view → testa il 403.
  def member_headers
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project:)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{member_secret}" }
  end

  def get_work_context(target = ticket)
    get "/cli/v1/projects/#{project.id}/tickets/#{target.id}/work_context", headers: headers
  end

  describe "GET /cli/v1/projects/:project_id/tickets/:ticket_id/work_context" do
    it "senza bearer → 401" do
      get "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/work_context"

      expect(response).to have_http_status(:unauthorized)
    end

    it "owner con snapshot presente → 200 con payload, origine, digest, versione, attore e timestamp" do
      create(:work_context_snapshot, ticket: ticket, organization_id: organization.id, actor_name: "Host SA",
                                     digest: "digest-fisso", payload_version: 1,
                                     payload: { "references" => [ { "key" => "repo", "level" => "project", "instructions" => "Clona" } ],
                                                "procedures" => [] })

      get_work_context

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["digest"]).to eq("digest-fisso")
      expect(data["payload_version"]).to eq(1)
      expect(data["actor_name"]).to eq("Host SA")
      expect(data["generated_at"]).to be_present
      expect(data["payload"]["references"].first).to include("key" => "repo", "level" => "project", "instructions" => "Clona")
    end

    it "owner senza snapshot (ticket mai preso in carico) → 404 R404-TICKET-004" do
      get_work_context

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["code"]).to eq("R404-TICKET-004")
    end

    it "membro che vede il progetto ma senza tickets.audit.view → 403 R403-CLIAUTH-002" do
      create(:work_context_snapshot, ticket: ticket, organization_id: organization.id)

      get "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/work_context", headers: member_headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "ticket di un altro progetto/organizzazione → 404 (anti-BOLA)" do
      other_ticket = create(:ticket, organization: create(:organization))

      get "/cli/v1/projects/#{project.id}/tickets/#{other_ticket.id}/work_context", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end
end
