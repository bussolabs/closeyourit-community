# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::Analyze, type: :service do
  let(:site) { build(:seo_site, base_url: "https://sito.test") }

  # Una pagina "sana": ogni test peggiora solo ciò che vuole misurare, così un rilievo che compare
  # è colpa del difetto introdotto e non del contorno.
  def page(path: "/", **overrides)
    # `attributes: nil` è un caso legittimo (pagina rotta o vietata: non c'è HTML da leggere) e va
    # distinto dall'assenza dell'override.
    requested = overrides.fetch(:attributes, :unset)
    defaults = {
      title: "Un titolo onesto",
      meta_description: "Una descrizione onesta della pagina.",
      canonical_url: "https://sito.test#{path}",
      robots_directives: "index, follow",
      hreflangs: {},
      lang: "it",
      h1s: [ "Un titolo onesto" ],
      h2_count: 2,
      word_count: 500,
      jsonld_types: [ "WebSite" ],
      images_total: 2,
      images_without_alt: 0,
      internal_links: [],
      external_links_count: 0,
      html_bytes: 40_000,
      mixed_content: false
    }
    attributes = case requested
    when :unset then defaults
    when nil then nil
    else defaults.merge(requested)
    end

    {
      url: "https://sito.test#{path}", path:, status_code: 200, redirect_chain: [],
      response_time_ms: 200, in_sitemap: true, discovered_from: "sitemap",
      blocked_by_robots: false, error: nil, attributes:
    }.merge(overrides.except(:attributes))
  end

  def analyze(pages, **crawl_overrides)
    crawl = Seo::Crawl::Result.new(pages:, sitemap_urls: pages.map { |p| p[:url] }, **crawl_overrides)
    described_class.call(crawl:, site:)
  end

  def keys_for(pages, **crawl_overrides) = analyze(pages, **crawl_overrides).map(&:check_key)

  it "una pagina in ordine non produce rilievi" do
    expect(keys_for([ page ])).to be_empty
  end

  describe "indicizzabilità" do
    it "vede il noindex" do
      keys = keys_for([ page(attributes: { robots_directives: "noindex, follow" }) ])
      expect(keys).to include("noindex")
    end

    it "vede una pagina rotta e da dove arrivava" do
      candidates = analyze([ page(status_code: 404, attributes: nil) ])
      broken = candidates.find { |candidate| candidate.check_key == "broken_link" }

      expect(broken.evidence["status"]).to eq(404)
      expect(broken.evidence["from"]).to eq("sitemap")
    end

    it "vede una catena di redirect, non un salto solo" do
      expect(keys_for([ page(redirect_chain: [ "https://sito.test/vecchia" ]) ])).not_to include("redirect_chain")
      expect(keys_for([ page(redirect_chain: %w[https://sito.test/a https://sito.test/b]) ])).to include("redirect_chain")
    end

    it "vede un anello di redirect" do
      expect(keys_for([ page(error: "too_many_redirects", attributes: nil) ])).to eq([ "redirect_loop" ])
    end

    it "segnala il canonical mancante" do
      expect(keys_for([ page(attributes: { canonical_url: nil }) ])).to include("canonical_missing")
    end

    it "segnala il canonical che manda altrove una pagina che il sito vuole indicizzata" do
      expect(keys_for([ page(attributes: { canonical_url: "https://sito.test/altrove" }) ]))
        .to include("canonical_points_elsewhere")
    end

    it "non si lamenta per una barra finale di differenza" do
      expect(keys_for([ page(path: "/chi-siamo", attributes: { canonical_url: "https://sito.test/chi-siamo/" }) ]))
        .not_to include("canonical_points_elsewhere")
    end

    it "una pagina vietata da robots ma dichiarata nella sitemap è una contraddizione del sito" do
      blocked = page(blocked_by_robots: true, attributes: nil)
      expect(keys_for([ blocked ])).to eq([ "blocked_by_robots" ])
    end

    it "una pagina vietata e non dichiarata è una scelta, non un difetto" do
      blocked = page(blocked_by_robots: true, in_sitemap: false, attributes: nil)
      expect(keys_for([ blocked ])).to be_empty
    end
  end

  describe "struttura" do
    it "vede il titolo mancante e quello troppo lungo" do
      expect(keys_for([ page(attributes: { title: nil }) ])).to include("missing_title")
      expect(keys_for([ page(attributes: { title: "t" * 80 }) ])).to include("title_too_long")
    end

    it "vede la pagina senza h1 — il difetto che un punteggio verde non racconta" do
      expect(keys_for([ page(attributes: { h1s: [] }) ])).to include("missing_h1")
    end

    it "vede più h1 nella stessa pagina" do
      expect(keys_for([ page(attributes: { h1s: %w[Uno Due] }) ])).to include("multiple_h1")
    end

    it "chiede i dati strutturati alla home, non a ogni pagina" do
      expect(keys_for([ page(attributes: { jsonld_types: [] }) ])).to include("missing_jsonld")
      expect(keys_for([ page(path: "/interna", attributes: { jsonld_types: [] }) ])).not_to include("missing_jsonld")
    end
  end

  describe "contenuto e prestazioni" do
    it "vede una pagina quasi vuota" do
      expect(keys_for([ page(attributes: { word_count: 20 }) ])).to include("thin_content")
    end

    it "conta le immagini senza descrizione" do
      candidates = analyze([ page(attributes: { images_without_alt: 2, images_total: 3 }) ])
      found = candidates.find { |candidate| candidate.check_key == "images_without_alt" }

      expect(found.evidence).to include("without_alt" => 2, "total" => 3)
    end

    it "vede la pagina lenta e quella troppo pesante" do
      expect(keys_for([ page(response_time_ms: 4_000) ])).to include("slow_response")
      expect(keys_for([ page(attributes: { html_bytes: 900_000 }) ])).to include("oversized_html")
    end

    it "vede le risorse in chiaro dentro una pagina cifrata" do
      expect(keys_for([ page(attributes: { mixed_content: true }) ])).to include("mixed_content")
    end
  end

  describe "difetti che si vedono solo dall'alto" do
    it "trova i titoli duplicati fra pagine diverse" do
      pages = [ page(path: "/"), page(path: "/copia") ]
      candidates = analyze(pages)
      duplicate = candidates.find { |candidate| candidate.check_key == "duplicate_title" }

      expect(duplicate).to be_present
      expect(duplicate.url).to be_nil # è un rilievo del sito, non di una pagina
      expect(duplicate.evidence["groups"].first["urls"]).to contain_exactly("https://sito.test/", "https://sito.test/copia")
    end

    it "trova la pagina che sta nella sitemap ma che nessuno linka" do
      home = page(path: "/", attributes: { internal_links: [ "https://sito.test/prezzi" ] })
      linked = page(path: "/prezzi")
      orphan = page(path: "/dimenticata")

      keys = keys_for([ home, linked, orphan ])
      expect(keys).to include("orphan_page")
      candidates = analyze([ home, linked, orphan ])
      expect(candidates.find { |c| c.check_key == "orphan_page" }.url).to eq("https://sito.test/dimenticata")
    end

    it "trova la pagina raggiungibile ma fuori dalla sitemap" do
      crawl = Seo::Crawl::Result.new(pages: [ page(path: "/"), page(path: "/fuori", in_sitemap: false) ],
                                     sitemap_urls: [ "https://sito.test/" ])
      keys = described_class.call(crawl:, site:).map(&:check_key)

      expect(keys).to include("missing_from_sitemap")
    end

    it "tace sulla sitemap quando non c'è una sitemap con cui confrontarsi" do
      crawl = Seo::Crawl::Result.new(pages: [ page(path: "/", in_sitemap: false) ], sitemap_urls: [])
      keys = described_class.call(crawl:, site:).map(&:check_key)

      expect(keys).not_to include("missing_from_sitemap")
    end

    it "segnala sitemap e robots irraggiungibili" do
      expect(keys_for([ page ], sitemap_reachable: false)).to include("sitemap_unreachable")
      expect(keys_for([ page ], robots_reachable: false)).to include("robots_unreachable")
    end

    describe "hreflang" do
      it "vede la coppia che non si risponde" do
        it_page = page(path: "/", attributes: {
                         hreflangs: { "it" => "https://sito.test/", "en" => "https://sito.test/en" }
                       })
        en_page = page(path: "/en", attributes: { hreflangs: { "en" => "https://sito.test/en" } })

        candidates = analyze([ it_page, en_page ])
        broken = candidates.find { |candidate| candidate.check_key == "hreflang_not_reciprocal" }

        expect(broken.evidence["pairs"]).to include("from" => "https://sito.test/", "to" => "https://sito.test/en")
      end

      it "tace se la pagina puntata non è stata visitata: non si accusa ciò che non si è visto" do
        solo = page(path: "/", attributes: {
                      hreflangs: { "it" => "https://sito.test/", "en" => "https://altro.test/en", "x-default" => "https://sito.test/" }
                    })

        expect(keys_for([ solo ])).not_to include("hreflang_not_reciprocal")
      end

      it "chiede l'x-default a chi dichiara delle alternative" do
        pagina = page(path: "/", attributes: { hreflangs: { "it" => "https://sito.test/" } })

        expect(keys_for([ pagina ])).to include("hreflang_missing_x_default")
      end
    end
  end
end
