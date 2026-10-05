# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Projects::Settings", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401" do
    get "/cli/v1/projects/#{project.id}/settings"
    expect(response).to have_http_status(:unauthorized)
  end

  it "show → 200 con retention e flag correnti" do
    project.update_columns(quick_bug_report_enabled: false, analytics_enabled: true)

    get "/cli/v1/projects/#{project.id}/settings", headers: headers

    expect(response).to have_http_status(:ok)
    data = response.parsed_body["data"]
    expect(data["project_id"]).to eq(project.id)
    expect(data).to include("logs_retention_days", "analytics_retention_days",
                            "quick_bug_report_enabled", "analytics_enabled",
                            "secret_approval_enabled")
    expect(data["quick_bug_report_enabled"]).to be(false)
    expect(data["analytics_enabled"]).to be(true)
  end

  it "show → include secret_approval_enabled tra i flag (CYRA-138)" do
    project.update_columns(secret_approval_enabled: true)

    get "/cli/v1/projects/#{project.id}/settings", headers: headers

    expect(response.parsed_body["data"]["secret_approval_enabled"]).to be(true)
  end

  it "update commuta secret_approval_enabled (CYRA-138)" do
    project.update_columns(secret_approval_enabled: false)

    put "/cli/v1/projects/#{project.id}/settings", headers: headers, params: { secret_approval_enabled: true }

    expect(response).to have_http_status(:ok)
    expect(project.reload.secret_approval_enabled).to be(true)
  end

  it "update imposta la retention per-progetto (log/analytics)" do
    put "/cli/v1/projects/#{project.id}/settings", headers: headers,
                                                   params: { logs_retention_days: 45, analytics_retention_days: 120 }

    expect(response).to have_http_status(:ok)
    expect(project.reload.logs_retention_days).to eq(45)
    expect(project.analytics_retention_days).to eq(120)
  end

  it "update imposta la retention per-progetto errori/performance/uptime (CYRA-159), riflessa nel payload show" do
    put "/cli/v1/projects/#{project.id}/settings", headers: headers,
                                                   params: { errors_retention_days: 90, performance_retention_days: 60,
                                                             uptime_retention_days: 365 }

    expect(response).to have_http_status(:ok)
    project.reload
    expect(project.errors_retention_days).to eq(90)
    expect(project.performance_retention_days).to eq(60)
    expect(project.uptime_retention_days).to eq(365)

    get "/cli/v1/projects/#{project.id}/settings", headers: headers
    data = response.parsed_body["data"]
    expect(data["errors_retention_days"]).to eq(90)
    expect(data["performance_retention_days"]).to eq(60)
    expect(data["uptime_retention_days"]).to eq(365)
  end

  it "retention uptime fuori range → 422 R422-PROJECT-001" do
    put "/cli/v1/projects/#{project.id}/settings", headers: headers, params: { uptime_retention_days: 999 }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]["code"]).to eq("R422-PROJECT-001")
  end

  it "update commuta i flag di funzionalità (quick_bug/analytics)" do
    project.update_columns(quick_bug_report_enabled: false, analytics_enabled: false)

    put "/cli/v1/projects/#{project.id}/settings", headers: headers,
                                                   params: { quick_bug_report_enabled: true, analytics_enabled: true }

    expect(response).to have_http_status(:ok)
    expect(project.reload.quick_bug_report_enabled).to be(true)
    expect(project.analytics_enabled).to be(true)
  end

  it "show → include l'origin allowlist del public ingest (CYRA-109)" do
    project.update!(allowed_origins: [ "https://app.example" ])

    get "/cli/v1/projects/#{project.id}/settings", headers: headers

    expect(response.parsed_body["data"]["allowed_origins"]).to eq([ "https://app.example" ])
  end

  it "update imposta l'origin allowlist (array di origini)" do
    put "/cli/v1/projects/#{project.id}/settings", headers: headers,
                                                   params: { allowed_origins: [ "https://app.example", "https://b.example" ] }

    expect(response).to have_http_status(:ok)
    expect(project.reload.allowed_origins).to eq(%w[https://app.example https://b.example])
  end

  it "origin allowlist malformata → 422 R422-PROJECT-001" do
    put "/cli/v1/projects/#{project.id}/settings", headers: headers, params: { allowed_origins: [ "non-valida" ] }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]["code"]).to eq("R422-PROJECT-001")
  end

  it "update solo flag NON tocca la retention (applica solo i campi presenti)" do
    project.update!(logs_retention_days: 30)

    put "/cli/v1/projects/#{project.id}/settings", headers: headers, params: { quick_bug_report_enabled: true }

    expect(response).to have_http_status(:ok)
    expect(project.reload.logs_retention_days).to eq(30)
  end

  it "retention fuori range → 422 R422-PROJECT-001" do
    put "/cli/v1/projects/#{project.id}/settings", headers: headers, params: { logs_retention_days: 0 }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]["code"]).to eq("R422-PROJECT-001")
  end

  it "progetto di un'altra org → 404 (anti-BOLA)" do
    other = create(:project)

    get "/cli/v1/projects/#{other.id}/settings", headers: headers
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body["error"]["code"]).to eq("R404-SYSTEM-001")
  end

  context "membro che vede il progetto ma senza projects.edit" do
    let(:member) { create(:account) }
    let(:member_secret) { Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret] }

    before do
      create(:membership, account: member, organization:, role: :member)
      create(:project_membership, account: member, project:)
    end

    # Come il canale Member (require_edit su show E update): le impostazioni richiedono projects.edit.
    it "update → 403 R403-CLIAUTH-002" do
      put "/cli/v1/projects/#{project.id}/settings",
          headers: { "Authorization" => "Bearer #{member_secret}" }, params: { quick_bug_report_enabled: true }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "show → 403 R403-CLIAUTH-002 (settings gata da projects.edit)" do
      get "/cli/v1/projects/#{project.id}/settings",
          headers: { "Authorization" => "Bearer #{member_secret}" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end

  it "membro che NON vede il progetto → 404, non 403 (visibilità prima del permesso)" do
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

    get "/cli/v1/projects/#{project.id}/settings", headers: { "Authorization" => "Bearer #{member_secret}" }

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body["error"]["code"]).to eq("R404-SYSTEM-001")
  end
end
