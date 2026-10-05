# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tickets::Review", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:in_review) { create(:ticket_status, :in_review, organization:, position: 2) }
  let!(:in_progress) { create(:ticket_status, :in_progress, organization:, position: 1) }
  let!(:resolved) { create(:ticket_status, :done, organization:, position: 3) }
  let(:ticket) { create(:ticket, project:, organization:, status: in_review) }

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

  describe "POST review/rejection" do
    def reject(project_id: project.id, ticket_id: ticket.id, hdrs: headers, reason: "Manca il test")
      post "/cli/v1/projects/#{project_id}/tickets/#{ticket_id}/review/rejection",
           headers: hdrs, params: { reason: reason }
    end

    it "owner respinge → 200, status in progress, commento col motivo" do
      reject
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["status"]).to eq(in_progress.label)
      expect(ticket.reload.status).to eq(in_progress)
      expect(ticket.comments.last.body).to eq("Manca il test")
    end

    it "ticket non in review → 422 R422-TICKET-006, status invariato" do
      ticket.update!(status: in_progress)
      reject
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-TICKET-006")
      expect(ticket.reload.status).to eq(in_progress)
    end

    it "reason mancante → 422 R422-TICKET-007, status invariato" do
      reject(reason: "  ")
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-TICKET-007")
      expect(ticket.reload.status).to eq(in_review)
    end

    it "ticket di un'altra org → 404 (anti-BOLA)" do
      other = create(:ticket, organization: create(:organization))
      reject(project_id: other.project_id, ticket_id: other.id)
      expect(response).to have_http_status(:not_found)
    end

    it "membro che vede il progetto ma senza tickets.edit → 403" do
      reject(hdrs: member_headers)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "senza bearer → 401" do
      reject(hdrs: {})
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST review/approval" do
    def approve(project_id: project.id, ticket_id: ticket.id, hdrs: headers)
      post "/cli/v1/projects/#{project_id}/tickets/#{ticket_id}/review/approval", headers: hdrs
    end

    it "owner approva → 200, status sul primo done" do
      approve
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["status"]).to eq(resolved.label)
      expect(ticket.reload.status).to eq(resolved)
    end

    it "ticket non in review → 422 R422-TICKET-006" do
      ticket.update!(status: in_progress)
      approve
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-TICKET-006")
    end

    # CYRA-611 — il permesso `tickets.edit` non distingue: ce l'ha anche il service account dell'host,
    # che lo usa per portare il ticket in revisione quando consegna. Con quel solo gate la macchina
    # poteva firmare da sola il proprio via libera, e da lì il codice andava unito, taggato e
    # rilasciato senza che nessuna persona avesse guardato niente.
    it "l'identità di una macchina non approva → 403, e il ticket non si muove" do
      # La macchina ha DAVVERO `tickets.edit`: è il permesso che le serve per portare il ticket in
      # revisione quando consegna. È esattamente il punto — quel permesso non distingueva.
      org_macchina = create(:organization)
      progetto = create(:project, organization: org_macchina)
      create(:ticket_status, :in_progress, organization: org_macchina, position: 1)
      revisione = create(:ticket_status, :in_review, organization: org_macchina, position: 2)
      create(:ticket_status, :done, organization: org_macchina, position: 3)
      suo_ticket = create(:ticket, project: progetto, organization: org_macchina, status: revisione)
      macchina = create(:account, :service)
      create(:membership, account: macchina, organization: org_macchina, role: :owner)
      chiave = Accounts::ApiTokens::Issue.call(account: macchina, organization: org_macchina,
                                               name: "host").value[:secret]

      post "/cli/v1/projects/#{progetto.id}/tickets/#{suo_ticket.id}/review/approval",
           headers: { "Authorization" => "Bearer #{chiave}" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-TICKET-021")
      expect(suo_ticket.reload.status).to eq(revisione)
    end

    it "ticket di un'altra org → 404 (anti-BOLA)" do
      other = create(:ticket, organization: create(:organization))
      approve(project_id: other.project_id, ticket_id: other.id)
      expect(response).to have_http_status(:not_found)
    end

    it "membro che vede il progetto ma senza tickets.edit → 403" do
      approve(hdrs: member_headers)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "senza bearer → 401" do
      approve(hdrs: {})
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
