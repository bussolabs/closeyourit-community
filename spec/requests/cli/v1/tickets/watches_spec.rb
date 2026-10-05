# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tickets::Watches", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, project:, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401" do
    put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/watch"
    expect(response).to have_http_status(:unauthorized)
  end

  describe "PUT watch (segui)" do
    it "iscrive l'account → 200, watching true e sottoscrizione creata" do
      expect do
        put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/watch", headers: headers
      end.to change { ticket.subscriptions.where(account:).count }.from(0).to(1)

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["ticket_id"]).to eq(ticket.id)
      expect(data["watching"]).to be(true)
      expect(data["watchers_count"]).to be >= 1
    end

    it "è idempotente: un secondo PUT resta 200 con una sola sottoscrizione" do
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/watch", headers: headers
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/watch", headers: headers

      expect(response).to have_http_status(:ok)
      expect(ticket.subscriptions.where(account:).count).to eq(1)
    end

    it "ticket di un'altra org → 404 (anti-BOLA)" do
      other = create(:ticket, organization: create(:organization))
      put "/cli/v1/projects/#{other.project_id}/tickets/#{other.id}/watch", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE watch (smetti di seguire)" do
    it "disiscrive l'account → 200, watching false" do
      Ticketing::Subscription.ensure_for(ticket:, account:, source: :manual)

      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/watch", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["watching"]).to be(false)
      expect(ticket.subscriptions.where(account:).count).to eq(0)
    end

    it "è idempotente: disiscriversi senza essere iscritti resta 200" do
      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/watch", headers: headers
      expect(response).to have_http_status(:ok)
    end
  end

  # Baseline: chi VEDE il ticket può seguirlo, nessuna permission key richiesta.
  describe "autorizzazione (partecipazione = gate)" do
    it "un member che vede il progetto può seguire → 200" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      create(:project_membership, account: member, project:)
      member_headers = { "Authorization" => "Bearer #{Accounts::ApiTokens::Issue.call(account: member, organization:, name: 'CLI').value[:secret]}" }

      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/watch", headers: member_headers

      expect(response).to have_http_status(:ok)
      expect(ticket.subscriptions.where(account: member).count).to eq(1)
    end

    it "un member che NON vede il progetto → 404 (anti-BOLA, non 403)" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      member_headers = { "Authorization" => "Bearer #{Accounts::ApiTokens::Issue.call(account: member, organization:, name: 'CLI').value[:secret]}" }

      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/watch", headers: member_headers

      expect(response).to have_http_status(:not_found)
    end
  end
end
