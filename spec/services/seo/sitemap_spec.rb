# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::Sitemap, type: :service do
  before { allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ]) }

  it "legge le URL di un urlset" do
    stub_request(:get, "https://sito.test/sitemap.xml").to_return(status: 200, body: <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url><loc>https://sito.test/</loc></url>
        <url><loc>https://sito.test/chi-siamo</loc></url>
      </urlset>
    XML

    result = described_class.call(url: "https://sito.test/sitemap.xml")

    expect(result).to be_reachable
    expect(result.urls).to eq(%w[https://sito.test/ https://sito.test/chi-siamo])
  end

  it "segue un indice di sitemap per un livello" do
    stub_request(:get, "https://sito.test/sitemap.xml").to_return(status: 200, body: <<~XML)
      <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <sitemap><loc>https://sito.test/sitemap-pagine.xml</loc></sitemap>
      </sitemapindex>
    XML
    stub_request(:get, "https://sito.test/sitemap-pagine.xml").to_return(status: 200, body: <<~XML)
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url><loc>https://sito.test/prezzi</loc></url>
      </urlset>
    XML

    result = described_class.call(url: "https://sito.test/sitemap.xml")

    expect(result.urls).to eq([ "https://sito.test/prezzi" ])
  end

  it "una sitemap che non risponde è un fatto da riportare, non un errore da sollevare" do
    stub_request(:get, "https://sito.test/sitemap.xml").to_return(status: 404)

    result = described_class.call(url: "https://sito.test/sitemap.xml")

    expect(result).not_to be_reachable
    expect(result.urls).to be_empty
    expect(result.error).to eq("http_404")
  end

  it "non si fa portare fuori strada da un XML rotto" do
    stub_request(:get, "https://sito.test/sitemap.xml").to_return(status: 200, body: "non è xml")

    expect(described_class.call(url: "https://sito.test/sitemap.xml").urls).to be_empty
  end
end
