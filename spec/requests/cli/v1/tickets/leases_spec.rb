# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tickets::Leases", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYRA") }
  let(:ticket) { create(:ticket, project:, organization:) }
  let(:database_now) { Time.zone.parse("2026-08-06 09:00:00") }

  before do
    create(:membership, account:, organization:, role: :owner)
    allow(Agents::Leases::Clock).to receive(:current).and_return(database_now)
  end

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }
  let(:lease_path) { "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/lease" }

  # Membro che VEDE il progetto ma senza tickets.assign → testa il 403.
  def member_headers
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project:)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{member_secret}" }
  end

  describe "POST lease" do
    it "prende il ticket → 201 con titolare, scadenza e nome leggibile" do
      post lease_path, headers:, params: { ttl_seconds: 3600 }

      expect(response).to have_http_status(:created)
      body = response.parsed_body["data"]
      expect(body).to include("ticket" => ticket.code, "account_id" => account.id, "host_id" => nil)
      expect(body["held_by"]).to include("kind" => "account", "id" => account.id, "name" => account.name)
      expect(Time.zone.parse(body["expires_at"])).to eq(database_now + 3600.seconds)
    end

    it "senza ttl usa il default di 8 ore" do
      post lease_path, headers: headers

      expect(response).to have_http_status(:created)
      expect(Time.zone.parse(response.parsed_body["data"]["expires_at"])).to eq(database_now + 8.hours)
    end

    it "ripreso dallo stesso token → 200, senza estendere la scadenza" do
      post lease_path, headers:, params: { ttl_seconds: 3600 }
      post lease_path, headers:, params: { ttl_seconds: 3600 }

      expect(response).to have_http_status(:ok)
      expect(Agents::Lease.where(ticket:).sole.expires_at).to eq(database_now + 3600.seconds)
    end

    # Il difetto che questo esempio impedisce: con un run id stabile (per account o per token) il
    # rilascio scrive un tombstone che rende quel ticket NON PIÙ PRENDIBILE da quel titolare, per
    # sempre. Prendere → rilasciare → riprendere è il ciclo più normale che esista.
    it "dopo un rilascio lo stesso token può riprendere il ticket" do
      post lease_path, headers:, params: { ttl_seconds: 3600 }
      delete lease_path, headers: headers

      post lease_path, headers:, params: { ttl_seconds: 3600 }

      expect(response).to have_http_status(:created)
      expect(Agents::Lease.where(ticket:).sole.account_id).to eq(account.id)
    end

    it "riprende anche dopo che il proprio lease è scaduto" do
      post lease_path, headers:, params: { ttl_seconds: 3600 }
      Agents::Lease.where(ticket:).update_all(expires_at: database_now - 1.second)

      post lease_path, headers:, params: { ttl_seconds: 3600 }

      expect(response).to have_http_status(:created)
      expect(Agents::Lease.where(ticket:).sole.expires_at).to eq(database_now + 3600.seconds)
    end

    it "ticket già tenuto da un host → 409 R409-LEASE-001 con chi lo tiene" do
      host = create(:agent_host, organization:, hostname: "mac-mini-1")
      create(:agent_lease, organization:, ticket:, host:, expires_at: database_now + 1.hour)

      post lease_path, headers:, params: { ttl_seconds: 3600 }

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]["code"]).to eq("R409-LEASE-001")
      expect(response.parsed_body["error"]["details"]["holder"]["held_by"])
        .to include("kind" => "host", "id" => host.id, "name" => "mac-mini-1")
    end

    it "ttl fuori range → 422 R422-LEASE-001, senza scrivere" do
      post lease_path, headers:, params: { ttl_seconds: 0 }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-LEASE-001")
      expect(Agents::Lease.count).to eq(0)
    end

    it "ticket di un'altra org → 404 (anti-BOLA)" do
      other = create(:ticket, organization: create(:organization))
      post "/cli/v1/projects/#{other.project_id}/tickets/#{other.id}/lease", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "membro che vede il progetto ma senza tickets.assign → 403" do
      post lease_path, headers: member_headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "senza bearer → 401" do
      post lease_path

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "PUT lease" do
    it "prolunga il proprio lease" do
      post lease_path, headers:, params: { ttl_seconds: 600 }
      put lease_path, headers:, params: { ttl_seconds: 3600 }

      expect(response).to have_http_status(:ok)
      expect(Agents::Lease.where(ticket:).sole.expires_at).to eq(database_now + 3600.seconds)
    end

    it "lease di un altro titolare → 409, senza toccarlo" do
      host = create(:agent_host, organization:)
      lease = create(:agent_lease, organization:, ticket:, host:, expires_at: database_now + 1.hour)

      put lease_path, headers:, params: { ttl_seconds: 3600 }

      expect(response).to have_http_status(:conflict)
      expect(lease.reload.host_id).to eq(host.id)
    end

    it "nessun lease da prolungare → 404 R404-LEASE-002" do
      put lease_path, headers:, params: { ttl_seconds: 3600 }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["code"]).to eq("R404-LEASE-002")
    end

    # Il client non conserva stato locale: prolungare deve funzionare anche su un lease preso da un
    # altro canale (la pagina web) o da un processo precedente, senza sapere quale run id porti.
    it "prolunga un lease preso dalla pagina web, senza conoscerne il run" do
      create(:agent_lease, organization:, ticket:, host: nil, agent: nil, account:,
                           run_id: "web:#{SecureRandom.uuid}", expires_at: database_now + 60.seconds)

      put lease_path, headers:, params: { ttl_seconds: 3600 }

      expect(response).to have_http_status(:ok)
      expect(Agents::Lease.where(ticket:).sole.expires_at).to eq(database_now + 3600.seconds)
    end
  end

  describe "DELETE lease" do
    it "rilascia il proprio lease e libera il ticket" do
      post lease_path, headers:, params: { ttl_seconds: 3600 }

      delete lease_path, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to eq("released" => true)
      expect(Agents::Lease.where(ticket:)).not_to exist
    end

    it "lease di un altro titolare → 409, senza cancellarlo" do
      create(:agent_lease, organization:, ticket:, host: create(:agent_host, organization:),
                           expires_at: database_now + 1.hour)

      delete lease_path, headers: headers

      expect(response).to have_http_status(:conflict)
      expect(Agents::Lease.where(ticket:)).to exist
    end

    it "senza bearer → 401" do
      delete lease_path

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
