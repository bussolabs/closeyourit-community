# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Monitors", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:) }

  before do
    create(:membership, account:, organization:, role: :owner)
    project.environments << environment
    # L'uptime esiste solo su progetti uptime-capable (piattaforma web/server).
    project.project_platforms.create!(platform: create(:platform, :uptime_capable, organization:))
  end

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  # Membro che VEDE il progetto (project_membership) ma senza uptime.manage → testa il 403.
  def member_headers
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project:)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{member_secret}" }
  end

  it "senza bearer → 401" do
    get "/cli/v1/projects/#{project.id}/monitors"
    expect(response).to have_http_status(:unauthorized)
  end

  describe "GET index" do
    it "→ 200 con i monitor del progetto e meta di paginazione" do
      monitor = create(:uptime_monitor, project:, environment:)

      get "/cli/v1/projects/#{project.id}/monitors", headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |m| m["id"] }
      expect(ids).to include(monitor.id)
      expect(response.parsed_body["meta"]).to include("page", "per", "total", "total_pages")
    end

    it "progetto di un'altra org → 404 (anti-BOLA, set_project!)" do
      other = create(:uptime_monitor) # progetto/org propri del factory

      get "/cli/v1/projects/#{other.project_id}/monitors", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET show" do
    it "→ 200 con id del monitor" do
      monitor = create(:uptime_monitor, project:, environment:)

      get "/cli/v1/projects/#{project.id}/monitors/#{monitor.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["id"]).to eq(monitor.id)
    end

    it "monitor di un altro progetto della stessa org → 404 (scope progetto)" do
      other_project = create(:project, organization:)
      other_env = create(:environment, organization:)
      other_project.environments << other_env
      other_monitor = create(:uptime_monitor, project: other_project, environment: other_env)

      get "/cli/v1/projects/#{project.id}/monitors/#{other_monitor.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST create (gate uptime.manage)" do
    it "owner → 201, crea il monitor con created_by e name auto-derivato" do
      expect do
        post "/cli/v1/projects/#{project.id}/monitors", headers: headers, params: {
          environment_id: environment.id, url: "https://example.com/up", http_method: "GET",
          interval_seconds: 60, expected_status: 200, timeout_seconds: 5
        }
      end.to change(Uptime::Monitor, :count).by(1)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["name"]).to be_present
      expect(Uptime::Monitor.find(data["id"]).created_by).to eq(account)
    end

    it "url assente → 422 R422-MONITOR-001 con details" do
      post "/cli/v1/projects/#{project.id}/monitors", headers: headers, params: {
        environment_id: environment.id, url: "", http_method: "GET",
        interval_seconds: 60, expected_status: 200, timeout_seconds: 5
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-MONITOR-001")
      expect(response.parsed_body["error"]["details"]).to have_key("url")
    end

    it "assegna il monitor a un uptime group via group_id — parità Member" do
      group = create(:uptime_group, organization:)

      post "/cli/v1/projects/#{project.id}/monitors", headers: headers, params: {
        environment_id: environment.id, url: "https://example.com/up", group_id: group.id
      }

      expect(response).to have_http_status(:created)
      expect(Uptime::Monitor.find(response.parsed_body["data"]["id"]).group_id).to eq(group.id)
    end

    it "crea un monitor TCP con host e porta, esposti dal serializer (CYRA-151)" do
      post "/cli/v1/projects/#{project.id}/monitors", headers: headers, params: {
        environment_id: environment.id, check_type: "tcp", host: "db.example.com", port: 5432,
        latency_threshold_ms: 750
      }

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["check_type"]).to eq("tcp")
      expect(data["host"]).to eq("db.example.com")
      expect(data["port"]).to eq(5432)
      expect(data["latency_threshold_ms"]).to eq(750)
    end

    it "membro che vede il progetto ma senza uptime.manage → 403" do
      expect do
        post "/cli/v1/projects/#{project.id}/monitors", headers: member_headers, params: {
          environment_id: environment.id, url: "https://example.com/up", http_method: "GET",
          interval_seconds: 60, expected_status: 200, timeout_seconds: 5
        }
      end.not_to change(Uptime::Monitor, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end

  describe "PUT update (gate uptime.manage)" do
    let!(:monitor) { create(:uptime_monitor, project:, environment:, interval_seconds: 60) }

    it "owner aggiorna interval_seconds → 200 + dato nuovo" do
      put "/cli/v1/projects/#{project.id}/monitors/#{monitor.id}", headers: headers,
                                                                   params: { interval_seconds: 120 }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["interval_seconds"]).to eq(120)
      expect(monitor.reload.interval_seconds).to eq(120)
    end

    # CYRA-776: la soglia di conferma è configurabile anche dal terminale, e il dato torna nella
    # risposta (default 2).
    it "owner aggiorna la soglia di conferma → 200 + dato nuovo" do
      expect(monitor.failure_threshold).to eq(2)
      put "/cli/v1/projects/#{project.id}/monitors/#{monitor.id}", headers: headers,
                                                                   params: { failure_threshold: 4 }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["failure_threshold"]).to eq(4)
      expect(monitor.reload.failure_threshold).to eq(4)
    end

    it "validazione fallita (url vuoto) → 422 R422-MONITOR-001" do
      put "/cli/v1/projects/#{project.id}/monitors/#{monitor.id}", headers: headers, params: { url: "" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-MONITOR-001")
    end
  end

  describe "DELETE destroy (gate uptime.manage)" do
    let!(:monitor) { create(:uptime_monitor, project:, environment:) }

    it "owner elimina → 204 e monitor rimosso" do
      delete "/cli/v1/projects/#{project.id}/monitors/#{monitor.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Uptime::Monitor.exists?(monitor.id)).to be(false)
    end
  end

  describe "pause / resume (sub-resource, gate uptime.manage)" do
    let!(:monitor) { create(:uptime_monitor, project:, environment:, active: true) }

    it "PUT pause → 200 e active=false" do
      put "/cli/v1/projects/#{project.id}/monitors/#{monitor.id}/pause", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["active"]).to be(false)
      expect(monitor.reload.active).to be(false)
    end

    it "DELETE pause (resume) → 200 e active=true" do
      monitor.update!(active: false)

      delete "/cli/v1/projects/#{project.id}/monitors/#{monitor.id}/pause", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["active"]).to be(true)
      expect(monitor.reload.active).to be(true)
    end

    it "membro che vede il progetto ma senza uptime.manage → 403 e monitor invariato" do
      put "/cli/v1/projects/#{project.id}/monitors/#{monitor.id}/pause", headers: member_headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
      expect(monitor.reload.active).to be(true)
    end

    it "membro senza uptime.manage → DELETE pause (resume) 403 (guard destroy)" do
      monitor.update!(active: false)
      delete "/cli/v1/projects/#{project.id}/monitors/#{monitor.id}/pause", headers: member_headers

      expect(response).to have_http_status(:forbidden)
      expect(monitor.reload.active).to be(false)
    end
  end

  describe "publication (pubblica/ritira status page, gate uptime.manage)" do
    let!(:monitor) { create(:uptime_monitor, project:, environment:) }

    it "PUT publication → 200 e public_status_enabled=true" do
      put "/cli/v1/projects/#{project.id}/monitors/#{monitor.id}/publication", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["public_status_enabled"]).to be(true)
      expect(monitor.reload.public_status_enabled).to be(true)
    end

    it "DELETE publication (ritira) → 200 e public_status_enabled=false" do
      monitor.update_column(:public_status_enabled, true)

      delete "/cli/v1/projects/#{project.id}/monitors/#{monitor.id}/publication", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["public_status_enabled"]).to be(false)
      expect(monitor.reload.public_status_enabled).to be(false)
    end

    it "membro che vede il progetto ma senza uptime.manage → 403 e flag invariato" do
      put "/cli/v1/projects/#{project.id}/monitors/#{monitor.id}/publication", headers: member_headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
      expect(monitor.reload.public_status_enabled).to be(false)
    end

    it "monitor di un'altra org → 404 (anti-BOLA)" do
      other = create(:uptime_monitor)

      put "/cli/v1/projects/#{project.id}/monitors/#{other.id}/publication", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "gestione monitor gated (update/destroy)" do
    let(:monitor) { create(:uptime_monitor, project:, environment:) }

    it "membro senza uptime.manage → update 403 (guard)" do
      patch "/cli/v1/projects/#{project.id}/monitors/#{monitor.id}", headers: member_headers,
                                                                     params: { interval_seconds: 120 }
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "membro senza uptime.manage → destroy 403 (guard)" do
      delete "/cli/v1/projects/#{project.id}/monitors/#{monitor.id}", headers: member_headers
      expect(response).to have_http_status(:forbidden)
    end
  end
end
