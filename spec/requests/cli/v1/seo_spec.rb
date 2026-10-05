# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Seo", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  def site_for(target_project)
    environment = create(:environment, organization: target_project.organization)
    target_project.environments << environment
    create(:seo_site, project: target_project, environment:)
  end

  def issue_for(target_project, check_key: "missing_h1", **attrs)
    site = site_for(target_project)
    page = create(:seo_page, site:, url: "#{site.base_url}/chi-siamo")
    create(:seo_issue, site:, page:, check_key:, **attrs)
  end

  it "senza bearer → 401" do
    create(:membership, account:, organization:, role: :owner)
    get "/cli/v1/seo"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (vede tutto + triage)" do
    before { create(:membership, account:, organization:, role: :owner) }

    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "index → 200 con i rilievi dei progetti visibili e meta" do
      issue = issue_for(project)

      get "/cli/v1/seo", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |row| row["id"] }).to include(issue.id)
      expect(response.parsed_body["meta"]).to include("total")
    end

    it "ogni riga porta la prova, il progetto e il sito senza una seconda chiamata" do
      issue_for(project, severity: :critical, check_key: "noindex")

      get "/cli/v1/seo", headers: headers

      row = response.parsed_body["data"].first
      expect(row["evidence"]).to be_present
      expect(row["project"]).to include("key")
      expect(row["site"]).to include("base_url")
      expect(row["label"]).to be_present
    end

    it "filtra per gravità, stato e ambito" do
      issue_for(project, check_key: "noindex", severity: :critical)

      get "/cli/v1/seo", params: { severity: "low" }, headers: headers
      expect(response.parsed_body["data"]).to be_empty

      get "/cli/v1/seo", params: { area: "indexability" }, headers: headers
      expect(response.parsed_body["data"].size).to eq(1)

      get "/cli/v1/seo", params: { status: "ignored" }, headers: headers
      expect(response.parsed_body["data"]).to be_empty
    end

    it "un filtro fuori vocabolario non è un errore: si scarta e si vede tutto" do
      issue_for(project)

      get "/cli/v1/seo", params: { severity: "catastrofica" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].size).to eq(1)
    end

    it "show → 200; un rilievo di un altro progetto non esiste (404, non 403)" do
      mine = issue_for(project)
      theirs = issue_for(create(:project))

      get "/cli/v1/seo/#{mine.id}", headers: headers
      expect(response).to have_http_status(:ok)

      get "/cli/v1/seo/#{theirs.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "pages → 200 con le pagine viste" do
      site = site_for(project)
      create(:seo_page, site:, url: "#{site.base_url}/prezzi", path: "/prezzi")

      get "/cli/v1/seo/pages", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |row| row["path"] }).to include("/prezzi")
    end

    it "ignore e riapertura passano dalla stessa risorsa" do
      issue = issue_for(project)

      put "/cli/v1/seo/#{issue.id}/ignore", params: { triage_note: "pagina di servizio" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(issue.reload).to be_status_ignored
      expect(issue.triage_note).to eq("pagina di servizio")

      delete "/cli/v1/seo/#{issue.id}/ignore", headers: headers
      expect(issue.reload).to be_status_open
    end

    it "promotion → 201 con il ticket, e una seconda volta non ne apre un altro" do
      create(:ticket_status, organization:, code: "open", position: 0)
      create(:ticket_priority, organization:, code: "high", position: 0)
      issue = issue_for(project)

      expect { put "/cli/v1/seo/#{issue.id}/promotion", headers: headers }
        .to change(Ticketing::Ticket, :count).by(1)
      expect(response).to have_http_status(:created)

      put "/cli/v1/seo/#{issue.id}/promotion", headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-SEO-001")
    end

    it "rescan accoda la visita del sito indicato" do
      site = site_for(project)

      expect { post "/cli/v1/seo/rescan", params: { site_id: site.id }, headers: headers }
        .to have_enqueued_job(::Seo::AuditSiteJob).with(site.id)
      expect(response).to have_http_status(:ok)
    end
  end

  context "membro senza chiavi di triage" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, project:, account:)
    end

    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "legge l'elenco" do
      issue_for(project)

      get "/cli/v1/seo", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].size).to eq(1)
    end

    it "non può ignorare, né promuovere, né far ripartire una visita" do
      issue = issue_for(project)
      site = issue.site

      put "/cli/v1/seo/#{issue.id}/ignore", headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(issue.reload).to be_status_open

      put "/cli/v1/seo/#{issue.id}/promotion", headers: headers
      expect(response).to have_http_status(:forbidden)

      post "/cli/v1/seo/rescan", params: { site_id: site.id }, headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end
end
