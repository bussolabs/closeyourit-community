# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::SeoSites", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:) }

  before do
    project.environments << environment
    project.project_platforms.create!(platform: create(:platform, organization:, supports_analytics: true))
  end

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  context "owner" do
    before { create(:membership, account:, organization:, role: :owner) }

    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "index → 200 con i siti visibili" do
      site = create(:seo_site, project:, environment:, base_url: "https://acme.test")

      get "/cli/v1/seo_sites", headers: headers

      expect(response).to have_http_status(:ok)
      row = response.parsed_body["data"].find { |candidate| candidate["id"] == site.id }
      expect(row["base_url"]).to eq("https://acme.test")
      expect(row["project"]).to include("key")
      expect(row).to have_key("last_error")
      # L'elenco non paga i blocchi della scheda: chi cerca "dove sono i problemi" non li legge, e
      # ciascuno costerebbe altre query per riga.
      expect(row).not_to have_key("performance")
      expect(row).not_to have_key("last_audit")
      expect(row).not_to have_key("issues")
    end

    # CYRA-541 — la scheda intera di un sito da riga di comando: com'è configurato, quanti rilievi ha
    # aperti, com'è andato l'ultimo giro e quanto è veloce. Sono le stesse cose che si vedono
    # aprendo il sito dalle schermate, e i numeri devono essere gli stessi.
    it "show → 200 con configurazione, rilievi aperti, ultimo giro e misure di velocità" do
      site = create(:seo_site, :audited, project:, environment:,
                                         base_url: "https://acme.test", frequency: :weekly, max_pages: 30)
      create_list(:seo_page, 2, site:)
      create(:seo_issue, site:, page: nil, check_key: "missing_h1", severity: :high)
      create(:seo_issue, site:, page: nil, check_key: "noindex", severity: :critical)
      create(:seo_issue, :ignored, site:, page: nil, check_key: "thin_content")
      create(:seo_audit, :completed, site:)
      create(:seo_lab_run, :completed, :with_field, site:, strategy: :mobile)
      create(:integration_credential, :pagespeed, organization:)

      get "/cli/v1/seo_sites/#{site.id}", headers: headers

      expect(response).to have_http_status(:ok)
      scheda = response.parsed_body["data"]
      expect(scheda).to include("base_url" => "https://acme.test", "frequency" => "weekly",
                                "max_pages" => 30, "follow_sitemap" => true, "enabled" => true)
      # I rilievi aperti per gravità, come le chip della scheda: sono di QUESTO sito, non dell'organizzazione.
      expect(scheda["issues"]).to eq("open" => 2, "critical" => 1, "high" => 1, "ignored" => 1)
      expect(scheda["pages_count"]).to eq(2)
      expect(scheda["last_audit"]).to include("status" => "completed", "pages_count" => 12,
                                              "issues_open_count" => 3, "error" => nil)
      # CYRA-808 — quante di quelle pagine il giro NON è riuscito a leggere. Senza, «12 pagine» si
      # legge come dodici pagine controllate anche quando otto erano mute, e chi legge da riga di
      # comando resterebbe all'oscuro di ciò che le schermate ora dicono.
      expect(scheda["last_audit"]).to include("pages_unverified_count" => 0)
      # I punteggi e le misure dell'ultimo giro di laboratorio, gli stessi valori della scheda a schermo.
      # `measured_at` dice quando: un numero vecchio senza la sua data si legge come fresco.
      expect(scheda.dig("performance", "mobile", "measured_at")).to be_present
      expect(scheda.dig("performance", "mobile", "scores")).to include("performance" => 72, "seo" => 88)
      expect(scheda.dig("performance", "mobile", "score_ratings", "performance")).to eq("needs_improvement")
      expect(scheda.dig("performance", "mobile", "lab")).to include("lcp" => 2_842, "tbt" => 310)
      # Il p75 di campo con il suo verdetto: le soglie stanno in Seo::Vitals e nessun altro le riapplica.
      expect(scheda.dig("performance", "mobile", "field", "metrics")).to include("lcp" => 3_120, "inp" => 184)
      expect(scheda.dig("performance", "mobile", "field", "ratings"))
        .to include("lcp" => "needs_improvement", "inp" => "good")
      expect(scheda.dig("performance", "mobile", "field", "origin_fallback")).to be(false)
      # Nessuna misura su computer: la strategia non misurata non compare, non esce con i campi a nulla.
      expect(scheda["performance"]).not_to have_key("desktop")
      expect(scheda["lab_configured"]).to be(true)
    end

    it "show dice quante pagine l'ultimo giro non è riuscito a leggere" do
      site = create(:seo_site, :audited, project:, environment:)
      create(:seo_audit, :completed, site:, pages_count: 12, pages_unverified_count: 5)

      get "/cli/v1/seo_sites/#{site.id}", headers: headers

      expect(response.parsed_body.dig("data", "last_audit", "pages_unverified_count")).to eq(5)
    end

    # Scenario 3 — un sito appena dichiarato. Un blocco stampato vuoto si legge come «qui non c'è
    # niente da vedere» invece di «non è ancora successo niente».
    it "show di un sito mai controllato non stampa i blocchi dell'ultimo giro né delle misure" do
      site = create(:seo_site, project:, environment:)

      get "/cli/v1/seo_sites/#{site.id}", headers: headers

      expect(response).to have_http_status(:ok)
      scheda = response.parsed_body["data"]
      expect(scheda).not_to have_key("last_audit")
      expect(scheda).not_to have_key("performance")
      # I conteggi invece ci sono: zero rilievi aperti è una risposta, non un blocco vuoto.
      expect(scheda["issues"]).to eq("open" => 0, "critical" => 0, "high" => 0, "ignored" => 0)
      expect(scheda["pages_count"]).to eq(0)
      # Nessuno ha collegato il servizio di misura: senza questo le misure non arriveranno MAI, e un
      # blocco assente si leggerebbe come «è ancora presto».
      expect(scheda["lab_configured"]).to be(false)
    end

    # Una misura fallita non deve sparire con il blocco: il motivo è l'unica cosa che spiega perché
    # non ci sono numeri, e tacerlo è il degrado silenzioso che questo prodotto rifiuta.
    it "show dice perché la misura di velocità è fallita anche senza un giro riuscito" do
      site = create(:seo_site, project:, environment:, last_lab_error: "quota_exceeded",
                               last_lab_run_at: 2.hours.ago)

      get "/cli/v1/seo_sites/#{site.id}", headers: headers

      expect(response).to have_http_status(:ok)
      performance = response.parsed_body.dig("data", "performance")
      expect(performance["last_error"]).to eq("quota_exceeded")
      expect(performance["last_run_at"]).to be_present
      expect(performance).not_to have_key("mobile")
    end

    # Scenario 2 — visibilità: fuori dai progetti visibili il sito non esiste, e nulla di suo trapela.
    it "show di un sito di un'altra organizzazione non è leggibile" do
      other = create(:project)
      other_env = create(:environment, organization: other.organization)
      other.environments << other_env
      site = create(:seo_site, project: other, environment: other_env, base_url: "https://altrove.test")

      get "/cli/v1/seo_sites/#{site.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include("altrove.test")
    end

    it "create → 201 e la prima visita parte subito" do
      expect do
        post "/cli/v1/seo_sites", headers: headers, params: {
          project_id: project.id, environment_id: environment.id,
          base_url: "https://acme.test/", frequency: "weekly", max_pages: 30
        }
      end.to change(::Seo::Site, :count).by(1)

      expect(response).to have_http_status(:created)
      site = ::Seo::Site.last
      expect(site.base_url).to eq("https://acme.test")
      expect(site).to be_every_weekly
      expect(::Seo::AuditSiteJob).to have_been_enqueued.with(site.id)
    end

    it "un indirizzo interno viene rifiutato con il campo che lo dice" do
      post "/cli/v1/seo_sites", headers: headers, params: {
        project_id: project.id, environment_id: environment.id, base_url: "http://10.0.0.9"
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-SEO-002")
      expect(response.parsed_body.dig("error", "details")).to have_key("base_url")
    end

    it "update cambia cadenza e tetto" do
      site = create(:seo_site, project:, environment:)

      patch "/cli/v1/seo_sites/#{site.id}", headers: headers, params: { frequency: "weekly", max_pages: 10 }

      expect(response).to have_http_status(:ok)
      expect(site.reload).to be_every_weekly
      expect(site.max_pages).to eq(10)
    end

    it "destroy rimuove il sito" do
      site = create(:seo_site, project:, environment:)

      expect { delete "/cli/v1/seo_sites/#{site.id}", headers: headers }.to change(::Seo::Site, :count).by(-1)
      expect(response).to have_http_status(:ok)
    end

    it "un sito di un'altra organizzazione non esiste" do
      other = create(:project)
      other_env = create(:environment, organization: other.organization)
      other.environments << other_env
      site = create(:seo_site, project: other, environment: other_env)

      patch "/cli/v1/seo_sites/#{site.id}", headers: headers, params: { max_pages: 5 }

      expect(response).to have_http_status(:not_found)
    end
  end

  context "membro senza seo.manage" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, project:, account:)
    end

    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "vede l'elenco ma non può dichiarare un sito" do
      create(:seo_site, project:, environment:)

      get "/cli/v1/seo_sites", headers: headers
      expect(response).to have_http_status(:ok)

      # La scheda è lettura: la governa l'accesso al progetto, non una chiave di configurazione.
      site = ::Seo::Site.last
      get "/cli/v1/seo_sites/#{site.id}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "id")).to eq(site.id)

      expect do
        post "/cli/v1/seo_sites", headers: headers, params: {
          project_id: project.id, environment_id: environment.id, base_url: "https://altro.test"
        }
      end.not_to change(::Seo::Site, :count)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
