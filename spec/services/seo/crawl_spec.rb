# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::Crawl, type: :service do
  let(:site) { build(:seo_site, base_url: "https://sito.test", max_pages: 10) }

  before { allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ]) }

  def html(body) = { status: 200, body:, headers: { "Content-Type" => "text/html" } }

  def stub_page(path, links: [], title: "Pagina")
    anchors = links.map { |href| %(<a href="#{href}">link</a>) }.join
    stub_request(:get, "https://sito.test#{path}")
      .to_return(html("<html lang='it'><head><title>#{title}</title></head><body><h1>#{title}</h1>#{anchors}</body></html>"))
  end

  # pause: 0 — la pausa fra le richieste è gentilezza verso il sito, non logica da verificare qui.
  def crawl = described_class.call(site:, pause: 0)

  before do
    stub_request(:get, "https://sito.test/robots.txt").to_return(status: 404)
    stub_request(:get, "https://sito.test/sitemap.xml").to_return(status: 404)
  end

  it "parte dalla home e segue i link interni" do
    stub_page("/", links: %w[/chi-siamo /prezzi])
    stub_page("/chi-siamo")
    stub_page("/prezzi")

    result = crawl

    expect(result.pages.map { |page| page[:path] }).to contain_exactly("/", "/chi-siamo", "/prezzi")
    expect(result.pages.first[:attributes][:title]).to eq("Pagina")
  end

  it "non esce dal sito: i link verso fuori si contano, non si seguono" do
    stub_page("/", links: %w[https://altro.test/pagina])
    esterno = stub_request(:get, "https://altro.test/pagina")

    result = crawl

    expect(result.pages.size).to eq(1)
    expect(esterno).not_to have_been_requested
    expect(result.pages.first[:attributes][:external_links_count]).to eq(1)
  end

  it "si ferma al tetto di pagine dichiarato dal sito" do
    site.max_pages = 2
    stub_page("/", links: %w[/a /b /c])
    stub_page("/a")
    stub_page("/b")
    stub_page("/c")

    expect(crawl.pages.size).to eq(2)
  end

  it "non visita due volte la stessa pagina" do
    stub_page("/", links: %w[/ciclo])
    ciclo = stub_page("/ciclo", links: %w[/ /ciclo])

    crawl

    expect(ciclo).to have_been_requested.once
  end

  describe "robots.txt" do
    it "non scarica ciò che è vietato" do
      stub_request(:get, "https://sito.test/robots.txt")
        .to_return(status: 200, body: "User-agent: *\nDisallow: /admin")
      stub_page("/", links: %w[/admin])
      admin = stub_request(:get, "https://sito.test/admin")

      result = crawl

      expect(admin).not_to have_been_requested
      expect(result.pages.find { |page| page[:path] == "/admin" }).to include(blocked_by_robots: true)
    end

    it "segnala quando il file non risponde, senza per questo vietare niente" do
      stub_page("/")

      result = crawl

      expect(result.robots_reachable).to be(false)
      expect(result.pages.size).to eq(1)
    end

    it "usa la sitemap dichiarata dal robots.txt, non quella indovinata" do
      stub_request(:get, "https://sito.test/robots.txt")
        .to_return(status: 200, body: "Sitemap: https://sito.test/mappa.xml\nUser-agent: *\nDisallow:")
      stub_request(:get, "https://sito.test/mappa.xml").to_return(status: 200, body: <<~XML)
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://sito.test/nascosta</loc></url>
        </urlset>
      XML
      stub_page("/")
      stub_page("/nascosta")

      result = crawl

      expect(result.sitemap_urls).to eq([ "https://sito.test/nascosta" ])
      expect(result.pages.map { |page| page[:path] }).to include("/nascosta")
      expect(result.pages.find { |page| page[:path] == "/nascosta" }[:in_sitemap]).to be(true)
    end
  end

  it "registra una pagina rotta invece di saltarla" do
    stub_page("/", links: %w[/sparita])
    stub_request(:get, "https://sito.test/sparita").to_return(status: 404)

    page = crawl.pages.find { |candidate| candidate[:path] == "/sparita" }

    expect(page[:status_code]).to eq(404)
    expect(page[:attributes]).to be_nil
    expect(page[:discovered_from]).to eq("https://sito.test/")
  end

  it "un guasto durante la visita non fa saltare tutto il giro" do
    allow(Seo::Fetch).to receive(:call).and_raise(StandardError)

    expect(crawl.error).to eq("standard_error")
  end

  # CYRA-808 — il fatto grezzo dice fin dove siamo arrivati su quella pagina. È l'informazione che
  # più a valle distingue «il problema non c'è più» da «non l'abbiamo guardato».
  describe "quanto siamo riusciti a osservare" do
    it "una pagina letta davvero è analizzata" do
      stub_page("/")

      expect(crawl.pages.sole[:observation]).to eq(:analyzed)
    end

    it "una pagina che risponde senza darci HTML resta una risposta, non una lettura" do
      stub_page("/", links: %w[/listino.pdf])
      stub_request(:get, "https://sito.test/listino.pdf")
        .to_return(status: 200, body: "%PDF-1.4", headers: { "Content-Type" => "application/pdf" })

      pdf = crawl.pages.find { |page| page[:path] == "/listino.pdf" }

      expect(pdf[:observation]).to eq(:responded)
      expect(pdf[:attributes]).to be_nil
    end

    it "una pagina rotta ha comunque risposto" do
      stub_page("/", links: %w[/sparita])
      stub_request(:get, "https://sito.test/sparita").to_return(status: 404)

      expect(crawl.pages.find { |page| page[:path] == "/sparita" }[:observation]).to eq(:responded)
    end

    it "una pagina che va in timeout resta un tentativo" do
      stub_page("/", links: %w[/lenta])
      stub_request(:get, "https://sito.test/lenta").to_timeout

      lenta = crawl.pages.find { |page| page[:path] == "/lenta" }

      expect(lenta[:error]).to eq("timeout")
      expect(lenta[:observation]).to eq(:attempted)
    end

    it "una pagina vietata da robots.txt non l'abbiamo nemmeno aperta" do
      stub_request(:get, "https://sito.test/robots.txt")
        .to_return(status: 200, body: "User-agent: *\nDisallow: /admin")
      stub_page("/", links: %w[/admin])

      expect(crawl.pages.find { |page| page[:path] == "/admin" }[:observation]).to eq(:attempted)
    end
  end
end
