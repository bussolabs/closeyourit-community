# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::Extract, type: :service do
  let(:url) { "https://sito.test/chi-siamo" }

  def extract(html) = described_class.call(html:, url:)

  it "legge i pezzi che il motore di ricerca guarda per primi" do
    result = extract(<<~HTML)
      <html lang="it">
        <head>
          <title>Chi siamo — Acme</title>
          <meta name="description" content="La storia di Acme">
          <link rel="canonical" href="https://sito.test/chi-siamo">
          <meta name="robots" content="index, follow">
        </head>
        <body>
          <h1>Chi siamo</h1>
          <h2>Le origini</h2>
          <h2>Oggi</h2>
        </body>
      </html>
    HTML

    expect(result[:title]).to eq("Chi siamo — Acme")
    expect(result[:meta_description]).to eq("La storia di Acme")
    expect(result[:canonical_url]).to eq("https://sito.test/chi-siamo")
    expect(result[:robots_directives]).to eq("index, follow")
    expect(result[:lang]).to eq("it")
    expect(result[:h1s]).to eq([ "Chi siamo" ])
    expect(result[:h2_count]).to eq(2)
  end

  it "conta tutti gli h1, perché averne più d'uno è esattamente il difetto da vedere" do
    result = extract("<html><body><h1>Primo</h1><h1>Secondo</h1></body></html>")

    expect(result[:h1s]).to eq(%w[Primo Secondo])
  end

  it "conta le parole che un lettore vede, non gli script" do
    result = extract(<<~HTML)
      <html><body>
        <script>var parole = "una due tre quattro cinque sei sette otto";</script>
        <style>.classe { content: "nove dieci"; }</style>
        <p>Queste sono cinque parole vere.</p>
      </body></html>
    HTML

    expect(result[:word_count]).to eq(5)
  end

  it "separa i link interni da quelli verso fuori e scarta ancore e mailto" do
    result = extract(<<~HTML)
      <html><body>
        <a href="/contatti">Contatti</a>
        <a href="https://sito.test/prezzi">Prezzi</a>
        <a href="https://altro.test/pagina">Altrove</a>
        <a href="#sezione">Ancora</a>
        <a href="mailto:ciao@sito.test">Scrivici</a>
      </body></html>
    HTML

    expect(result[:internal_links]).to contain_exactly("https://sito.test/contatti", "https://sito.test/prezzi")
    expect(result[:external_links_count]).to eq(1)
  end

  it "conta le immagini senza testo alternativo" do
    result = extract(<<~HTML)
      <html><body>
        <img src="/a.png" alt="Descritta">
        <img src="/b.png" alt="">
        <img src="/c.png">
      </body></html>
    HTML

    expect(result[:images_total]).to eq(3)
    expect(result[:images_without_alt]).to eq(2)
  end

  it "raccoglie gli hreflang dichiarati, risolvendo gli indirizzi relativi" do
    result = extract(<<~HTML)
      <html><head>
        <link rel="alternate" hreflang="it" href="/chi-siamo">
        <link rel="alternate" hreflang="en" href="https://sito.test/about">
        <link rel="alternate" hreflang="x-default" href="https://sito.test/about">
      </head><body></body></html>
    HTML

    expect(result[:hreflangs]).to eq(
      "it" => "https://sito.test/chi-siamo",
      "en" => "https://sito.test/about",
      "x-default" => "https://sito.test/about"
    )
  end

  it "riconosce i tipi dei dati strutturati, anche dentro un @graph" do
    result = extract(<<~HTML)
      <html><head>
        <script type="application/ld+json">
          {"@context":"https://schema.org","@graph":[{"@type":"Organization"},{"@type":"WebSite"}]}
        </script>
      </head><body></body></html>
    HTML

    expect(result[:jsonld_types]).to contain_exactly("Organization", "WebSite")
  end

  it "un JSON-LD rotto è un fatto, non un silenzio" do
    result = extract('<html><head><script type="application/ld+json">{rotto</script></head><body></body></html>')

    expect(result[:jsonld_types]).to eq([ "invalid" ])
  end

  it "vede le risorse in chiaro dentro una pagina cifrata" do
    result = extract('<html><body><img src="http://sito.test/logo.png"></body></html>')

    expect(result[:mixed_content]).to be(true)
  end

  it "una pagina tutta https non ha contenuto misto" do
    result = extract('<html><body><img src="https://sito.test/logo.png"></body></html>')

    expect(result[:mixed_content]).to be(false)
  end

  it "su una pagina vuota risponde con dei vuoti, non con un errore" do
    result = extract("")

    expect(result[:title]).to be_nil
    expect(result[:h1s]).to eq([])
    expect(result[:word_count]).to eq(0)
    expect(result[:internal_links]).to eq([])
  end
end
