# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Servers", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401" do
    get "/cli/v1/servers"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (servers.view + servers.manage impliciti)" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "index → 200 con la fleet dell'org e meta di paginazione" do
      host = create(:server_host, organization:, name: "apps", status: :up, cpu_pct: 12.5)

      get "/cli/v1/servers", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data.map { |x| x["id"] }).to include(host.id)
      row = data.find { |x| x["id"] == host.id }
      expect(row["name"]).to eq("apps")
      expect(row["status"]).to eq("up")
      expect(row["cpu_pct"]).to eq("12.5")
      expect(row).not_to have_key("token_digest")
      expect(response.parsed_body["meta"]).to include("page", "per", "total", "total_pages")
    end

    it "index esclude gli host di un'altra org (anti-BOLA)" do
      mine = create(:server_host, organization:)
      other = create(:server_host)

      get "/cli/v1/servers", headers: headers

      ids = response.parsed_body["data"].map { |x| x["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(other.id)
    end

    it "index filtra per status" do
      up = create(:server_host, organization:, status: :up, last_seen_at: Time.current)
      down = create(:server_host, organization:, status: :down)

      get "/cli/v1/servers", params: { status: [ "down" ] }, headers: headers

      ids = response.parsed_body["data"].map { |x| x["id"] }
      expect(ids).to include(down.id)
      expect(ids).not_to include(up.id)
    end

    it "show → 200 con lo snapshot" do
      host = create(:server_host, organization:, name: "worker", os_name: "Ubuntu 24.04",
                    services_total: 40, services_failed: 1)

      get "/cli/v1/servers/#{host.id}", headers: headers

      data = response.parsed_body["data"]
      expect(data["name"]).to eq("worker")
      expect(data["os_name"]).to eq("Ubuntu 24.04")
      expect(data["services_failed"]).to eq(1)
    end

    it "show di un host di un'altra org → 404 (anti-BOLA)" do
      other = create(:server_host)

      get "/cli/v1/servers/#{other.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["code"]).to eq("R404-SYSTEM-001")
    end

    it "update rinomina l'host" do
      host = create(:server_host, organization:, name: "vecchio")

      put "/cli/v1/servers/#{host.id}", params: { confirm: "1", name: "nuovo" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(host.reload.name).to eq("nuovo")
    end

    # CYRA-519 — i nomi che su una macchina non sono servizi si scrivevano solo dalla pagina web:
    # chi lavora da terminale non aveva modo di sistemare una lista di due righe.
    describe "contenitori da ignorare" do
      it "si leggono nella scheda della macchina" do
        host = create(:server_host, organization:, ignored_container_patterns: %w[buildkit runner])

        get "/cli/v1/servers/#{host.id}", headers: headers

        expect(response.parsed_body["data"]["ignored_container_patterns"]).to eq(%w[buildkit runner])
      end

      it "si scrivono come elenco" do
        host = create(:server_host, organization:)

        put "/cli/v1/servers/#{host.id}", params: { confirm: "1", ignored_container_patterns: %w[buildkit runner] },
                                          headers: headers

        expect(response).to have_http_status(:ok)
        expect(host.reload.ignored_container_patterns).to eq(%w[buildkit runner])
      end

      it "si scrivono anche come riga sola, separati da virgola" do
        host = create(:server_host, organization:)

        put "/cli/v1/servers/#{host.id}", params: { confirm: "1", ignored_container_patterns: "buildkit, runner" },
                                          headers: headers

        expect(host.reload.ignored_container_patterns).to eq(%w[buildkit runner])
      end

      # Il punto che il ticket chiedeva di verificare: cambiare il nome non deve azzerare la lista.
      it "un aggiornamento parziale non azzera quello che non gli è stato passato" do
        host = create(:server_host, organization:, name: "vecchio", ignored_container_patterns: %w[buildkit])

        put "/cli/v1/servers/#{host.id}", params: { confirm: "1", name: "nuovo" }, headers: headers

        expect(host.reload.name).to eq("nuovo")
        expect(host.ignored_container_patterns).to eq(%w[buildkit])
      end

      it "si svuotano passando un elenco vuoto" do
        host = create(:server_host, organization:, ignored_container_patterns: %w[buildkit])

        put "/cli/v1/servers/#{host.id}", params: { confirm: "1", ignored_container_patterns: [] }, headers: headers

        expect(host.reload.ignored_container_patterns).to eq([])
      end
    end

    it "update con name vuoto → 422 R422-SERVER-005" do
      host = create(:server_host, organization:, name: "apps")

      put "/cli/v1/servers/#{host.id}", params: { confirm: "1", name: "" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-SERVER-005")
      expect(host.reload.name).to eq("apps")
    end

    it "pause → paused, resume → pending" do
      host = create(:server_host, organization:, status: :up)

      put "/cli/v1/servers/#{host.id}/pause", params: { confirm: "1" }, headers: headers
      expect(response.parsed_body["data"]["status"]).to eq("paused")
      expect(host.reload.status_paused?).to be(true)

      put "/cli/v1/servers/#{host.id}/resume", params: { confirm: "1" }, headers: headers
      expect(host.reload.status_pending?).to be(true)
    end

    it "revoke marca revoked_at, unrevoke lo azzera" do
      host = create(:server_host, organization:)

      put "/cli/v1/servers/#{host.id}/revoke", params: { confirm: "1" }, headers: headers
      expect(host.reload.revoked?).to be(true)
      expect(response.parsed_body["data"]["revoked_at"]).to be_present

      put "/cli/v1/servers/#{host.id}/unrevoke", params: { confirm: "1" }, headers: headers
      expect(host.reload.revoked?).to be(false)
    end

    it "destroy elimina host e serie" do
      host = create(:server_host, organization:)
      create(:server_sample, host: host)

      expect { delete "/cli/v1/servers/#{host.id}", params: { confirm: "1" }, headers: headers }
        .to change(Servers::Host, :count).by(-1)
        .and change(Servers::Sample, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end
  end

  context "member senza permessi" do
    before { create(:membership, account:, organization:, role: :member) }

    it "index → 403 R403-CLIAUTH-002 (anche la lettura è gated)" do
      get "/cli/v1/servers", headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end

  context "member con solo servers.view via ruolo" do
    before do
      create(:membership, account:, organization:, role: :member)
      role = create(:role, organization:, name: "Ops viewer")
      create(:role_permission, role:, permission_key: "servers.view")
      create(:account_role, account:, organization:, role:)
    end

    it "index → 200 (lettura consentita)" do
      create(:server_host, organization:)

      get "/cli/v1/servers", headers: headers

      expect(response).to have_http_status(:ok)
    end

    it "pause → 403 (mutazione richiede servers.manage)" do
      host = create(:server_host, organization:, status: :up)

      put "/cli/v1/servers/#{host.id}/pause", headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(host.reload.status_up?).to be(true)
    end
  end
end
