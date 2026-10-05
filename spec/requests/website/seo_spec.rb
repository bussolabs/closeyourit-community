# frozen_string_literal: true

require "rails_helper"

# SEO del sito marketing: sitemap XML con alternates, canonical + hreflang + Open Graph nell'head.
RSpec.describe "Website::Seo", type: :request do
  describe "GET /sitemap.xml" do
    it "elenca ogni pagina in entrambi i locali con alternates hreflang e x-default" do
      get "/sitemap.xml"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/xml")

      locs = response.body.scan(%r{<loc>([^<]+)</loc>}).flatten
      # CYRA-698 — la privacy è la quinta pagina del sito, e come le altre esiste nei due locali.
      pages_count = 2 + Website::FeaturePage.all.size * 2 + 2 + 2 + 2 # home + feature + integrations + access request + privacy, ×2 locali
      expect(locs.size).to eq(pages_count)
      expect(locs).to include(a_string_ending_with("/features/error-monitoring"))
      expect(locs).to include(a_string_ending_with("/it/funzionalita/error-monitoring"))
      expect(locs).to include(a_string_ending_with("/integrations"))
      expect(locs).to include(a_string_ending_with("/it/integrazioni"))
      expect(locs).to include(a_string_ending_with("/request-access"))
      expect(locs).to include(a_string_ending_with("/it/richiedi-accesso"))
      expect(locs).to include(a_string_ending_with("/privacy"))
      expect(locs).to include(a_string_ending_with("/it/privacy"))

      expect(response.body).to include('hreflang="en"')
      expect(response.body).to include('hreflang="it"')
      expect(response.body).to include('hreflang="x-default"')
    end
  end

  describe "head SEO delle pagine marketing" do
    it "landing EN: canonical, hreflang bidirezionali e Open Graph" do
      get "/"

      expect(response.body).to include('rel="canonical"')
      expect(response.body).to include(%(hreflang="en" href="http://www.example.com/"))
      expect(response.body).to include(%(hreflang="it" href="http://www.example.com/it"))
      expect(response.body).to include('hreflang="x-default"')
      expect(response.body).to include('property="og:title"')
      expect(response.body).to include('property="og:image"')
      expect(response.body).to include('name="twitter:card"')
      expect(response.body).to include('name="description"')
    end

    it "pagina feature IT: canonical IT e alternate EN incrociato" do
      get "/it/funzionalita/logs"

      expect(response.body).to include(%(rel="canonical" href="http://www.example.com/it/funzionalita/logs"))
      expect(response.body).to include(%(hreflang="en" href="http://www.example.com/features/logs"))
      expect(response.body).to include('content="it_IT"')
    end

    it "la status page pubblica NON riceve i tag marketing" do
      org = create(:organization, slug: "acme")
      project = create(:project, organization: org, key: "MYAP")
      environment = create(:environment, organization: org, code: "production").tap { |e| project.environments << e }
      create(:uptime_monitor, project:, environment:, public_status_enabled: true)

      get public_status_path("acme", "MYAP", "production")

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('rel="canonical"')
      expect(response.body).not_to include('property="og:title"')
    end
  end

  # CYRA-238 — Structured data (JSON-LD): Organization+WebSite sulla home, SoftwareApplication+
  # BreadcrumbList sulle pagine feature, nessuno sulla status page (stesso guard del resto della SEO).
  describe "JSON-LD" do
    def ld_json_blocks(body)
      Nokogiri::HTML(body).css('script[type="application/ld+json"]').map { |node| JSON.parse(node.text) }
    end

    it "home: esattamente Organization e WebSite" do
      get "/"

      blocks = ld_json_blocks(response.body)
      types = blocks.map { |block| block["@type"] }
      expect(types).to contain_exactly("Organization", "WebSite")

      organization = blocks.find { |block| block["@type"] == "Organization" }
      expect(organization["name"]).to eq("CloseYourIt")
      expect(organization["url"]).to eq("http://www.example.com")
      expect(organization["logo"]).to eq("http://www.example.com/icon.svg")
    end

    it "pagina feature: SoftwareApplication e BreadcrumbList coerenti con la feature corrente" do
      get "/features/logs"

      blocks = ld_json_blocks(response.body)
      types = blocks.map { |block| block["@type"] }
      expect(types).to contain_exactly("SoftwareApplication", "BreadcrumbList")

      app = blocks.find { |block| block["@type"] == "SoftwareApplication" }
      expect(app["name"]).to eq("CloseYourIt")

      breadcrumb = blocks.find { |block| block["@type"] == "BreadcrumbList" }
      items = breadcrumb["itemListElement"]
      expect(items.size).to eq(2)
      expect(items.last["name"]).to eq(I18n.t("website.features.logs.name", locale: :en))
      expect(items.last["item"]).to eq("http://www.example.com/features/logs")
    end

    it "la status page pubblica NON riceve JSON-LD" do
      org = create(:organization, slug: "acme")
      project = create(:project, organization: org, key: "MYAP")
      environment = create(:environment, organization: org, code: "production").tap { |e| project.environments << e }
      create(:uptime_monitor, project:, environment:, public_status_enabled: true)

      get public_status_path("acme", "MYAP", "production")

      expect(response).to have_http_status(:ok)
      expect(ld_json_blocks(response.body)).to be_empty
    end
  end
end
