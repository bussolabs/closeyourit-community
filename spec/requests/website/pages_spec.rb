# frozen_string_literal: true

require "rails_helper"

# Sito marketing pubblico (canale Website::): landing, pagine feature, integrations.
# EN default senza prefisso ("/"), IT sotto "/it" con segmenti tradotti (rules/rails/i18n.md).
RSpec.describe "Website::Pages", type: :request do
  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET / (dual root)" do
    it "guest → landing marketing EN, senza login" do
      get "/"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="website-home"')
      expect(response.body).to include('<html lang="en"')
    end

    it "autenticato → dashboard member (root invariata per chi è loggato)" do
      org = create(:organization)
      account = create(:account)
      create(:membership, account: account, organization: org, role: :owner)
      sign_in(account)

      get "/"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="home-queue-bar"')
      expect(response.body).not_to include('data-test="website-home"')
    end

    it "skip-link al contenuto + <main> con id corrispondente (a11y)" do
      get "/"
      doc = Nokogiri::HTML(response.body)
      skip_link = doc.at_css("[data-test='skip-link']")
      expect(skip_link).to be_present
      expect(skip_link["href"]).to eq("#main-content")
      expect(doc.at_css("main#main-content")).to be_present
    end

    it "il <nav> dell'header ha un aria-label (a11y)" do
      get "/"
      nav = Nokogiri::HTML(response.body).at_css("[data-test='website-header'] nav")
      expect(nav["aria-label"]).to be_present
    end

    it "racconta il flusso operativo e usa la richiesta accesso come CTA" do
      get "/it"
      doc = Nokogiri::HTML(response.body)
      expect(doc.css("[data-test^='workflow-step-']").size).to eq(4)
      expect(doc.text).to include("ERR-1284", "a41f-9c02", "DRRA-321", "v2.4.2")
      expect(doc.css("a[href='#{request_access_it_path}']").size).to be >= 2
    end
  end

  describe "GET /it (landing IT)" do
    it "risponde 200 con la landing in italiano" do
      get "/it"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="website-home"')
      expect(response.body).to include('<html lang="it"')
    end
  end

  describe "GET /features/:slug" do
    Website::FeaturePage.all.each do |page|
      it "#{page.slug} → 200 EN" do
        get "/features/#{page.slug}"
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(data-test="website-feature-#{page.slug}"))
        expect(response.body).to include('<html lang="en"')
      end

      it "#{page.slug} → 200 IT su /it/funzionalita" do
        get "/it/funzionalita/#{page.slug}"
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(data-test="website-feature-#{page.slug}"))
        expect(response.body).to include('<html lang="it"')
      end
    end

    it "slug sconosciuto → 404 (EN e IT)" do
      get "/features/nope"
      expect(response).to have_http_status(:not_found)

      get "/it/funzionalita/nope"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /integrations" do
    it "risponde 200 EN" do
      get "/integrations"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="website-integrations"')
    end

    it "risponde 200 IT su /it/integrazioni" do
      get "/it/integrazioni"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="website-integrations"')
      expect(response.body).to include('<html lang="it"')
    end

    it "i comandi/DSN nei terminali sono esposti agli AT (contenuto, non decorazione)" do
      get "/integrations"
      doc = Nokogiri::HTML(response.body)
      %w[ruby dart cli ci sentry].each do |key|
        block = doc.at_css("[data-test='website-integration-#{key}'] pre")
        expect(block).to be_present, "manca il blocco #{key}"
        expect(block.ancestors.map { |a| a["aria-hidden"] }).not_to include("true")
      end
    end
  end

  describe "locale isolato per-request" do
    it "una richiesta IT non sposta il locale delle richieste successive" do
      get "/it"
      get "/"
      expect(response.body).to include('<html lang="en"')
    end
  end

  describe "richiesta di accesso" do
    it "mostra il form e salva una richiesta valida" do
      get "/it/richiedi-accesso"
      expect(response.body).to include('data-test="access-request-form"')
      expect do
        post "/it/richiedi-accesso", params: { website_access_request: { name: "Ada", email: "ADA@example.com", team: "Team", context: "Errori e ticket" } }
      end.to change(Website::AccessRequest, :count).by(1)
      expect(response).to redirect_to(request_access_it_path(sent: "1"))
      expect(Website::AccessRequest.last.email).to eq("ada@example.com")
    end

    it "rende gli errori accessibili" do
      post "/request-access", params: { website_access_request: { name: "", email: "bad", team: "", context: "" } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('role="alert"')
    end
  end
end
