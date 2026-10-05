# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::AuditSite, type: :service do
  let(:site) { create(:seo_site, base_url: "https://sito.test") }
  let(:now) { Time.current.change(usec: 0) }

  def page_fact(path: "/", **overrides)
    {
      url: "https://sito.test#{path}", path:, status_code: 200, redirect_chain: [],
      response_time_ms: 100, in_sitemap: true, discovered_from: "sitemap",
      blocked_by_robots: false, error: nil, observation: :analyzed,
      attributes: {
        title: "Titolo", meta_description: "Descrizione", canonical_url: "https://sito.test#{path}",
        robots_directives: nil, hreflangs: {}, lang: "it", h1s: [], h2_count: 0,
        word_count: 300, jsonld_types: [ "WebSite" ], images_total: 0, images_without_alt: 0,
        internal_links: [], external_links_count: 0, html_bytes: 10_000, mixed_content: false
      }
    }.merge(overrides)
  end

  def crawler_returning(result) = class_double(Seo::Crawl, call: result)

  it "un giro completo apre i rilievi e mette in pari il sito" do
    crawler = crawler_returning(Seo::Crawl::Result.new(pages: [ page_fact ], sitemap_urls: [ "https://sito.test/" ]))

    report = described_class.call(site:, now:, crawler:)

    expect(report.opened.map(&:check_key)).to include("missing_h1")
    expect(site.reload.last_audited_at).to eq(now)
    expect(site.next_audit_at).to eq(now + 1.day)
    expect(site.last_error).to be_nil
    expect(site.audits.sole).to be_status_completed
  end

  describe "quando il giro non riesce" do
    it "registra il fallimento invece di fingere che il sito sia a posto" do
      crawler = crawler_returning(Seo::Crawl::Result.new(error: "timeout"))

      expect(described_class.call(site:, now:, crawler:)).to be_nil

      audit = site.audits.sole
      expect(audit).to be_status_failed
      expect(audit.error).to eq("timeout")
      expect(site.reload.last_error).to eq("timeout")
    end

    it "un sito che non risponde non azzera i rilievi già aperti" do
      first = crawler_returning(Seo::Crawl::Result.new(pages: [ page_fact ], sitemap_urls: [ "https://sito.test/" ]))
      described_class.call(site:, now:, crawler: first)

      described_class.call(site:, now: now + 1.day, crawler: crawler_returning(Seo::Crawl::Result.new(error: "timeout")))

      expect(site.issues.status_open.count).to be_positive
    end

    it "zero pagine è un fallimento, non un sito perfetto" do
      crawler = crawler_returning(Seo::Crawl::Result.new(pages: []))

      described_class.call(site:, now:, crawler:)

      expect(site.audits.sole.error).to eq("no_pages")
    end

    it "riprogramma comunque il prossimo giro, per non ritentare a ogni ora per sempre" do
      crawler = crawler_returning(Seo::Crawl::Result.new(error: "timeout"))

      described_class.call(site:, now:, crawler:)

      expect(site.reload.next_audit_at).to eq(now + 1.day)
    end
  end

  it "la frequenza settimanale sposta il prossimo giro di una settimana" do
    site.update!(frequency: :weekly)
    crawler = crawler_returning(Seo::Crawl::Result.new(pages: [ page_fact ], sitemap_urls: [ "https://sito.test/" ]))

    described_class.call(site:, now:, crawler:)

    expect(site.reload.next_audit_at).to eq(now + 7.days)
  end

  # CYRA-808 — lo scenario del ticket, dall'inizio alla fine: il problema c'era, il giro dopo la
  # pagina non risponde, e l'elenco NON deve migliorare da solo.
  it "una pagina che smette di rispondere non fa risultare risolti i suoi problemi" do
    pieno = crawler_returning(Seo::Crawl::Result.new(pages: [ page_fact ], sitemap_urls: [ "https://sito.test/" ]))
    described_class.call(site:, now:, crawler: pieno)
    expect(site.issues.status_open.map(&:check_key)).to include("missing_h1")

    muta = page_fact(status_code: nil, response_time_ms: nil, error: "timeout", attributes: nil,
                     observation: :attempted)
    cieco = crawler_returning(Seo::Crawl::Result.new(pages: [ muta ], sitemap_urls: [ "https://sito.test/" ]))
    described_class.call(site:, now: now + 1.day, crawler: cieco)

    expect(site.issues.status_open.map(&:check_key)).to include("missing_h1")
    expect(site.audits.recent.first.pages_unverified_count).to eq(1)
  end

  # CYRA-824 — chi ha la scheda aperta deve vedere l'esito senza ricaricarla a mano. Il segnale
  # parte da qui, dove il giro finisce davvero, e non dalla scrittura delle singole pagine: un sito
  # da cento pagine manderebbe cento segnali per un solo esito.
  describe "il segnale a chi sta guardando la scheda" do
    let(:stream) { Realtime::Streams.seo_site(site) }

    # In test la cache è null_store (ogni write "riesce") → il throttle non si vedrebbe.
    before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

    it "parte quando il giro comincia e quando finisce" do
      crawler = crawler_returning(Seo::Crawl::Result.new(pages: [ page_fact ], sitemap_urls: [ "https://sito.test/" ]))

      expect { described_class.call(site:, now:, crawler:) }.to have_broadcasted_to(stream).at_least(:once)
    end

    # Il caso che conta più dell'altro: un giro fallito è proprio quello che chi guarda non può
    # indovinare da solo.
    it "parte anche quando il giro fallisce" do
      crawler = crawler_returning(Seo::Crawl::Result.new(error: "timeout"))

      expect { described_class.call(site:, now:, crawler:) }.to have_broadcasted_to(stream).at_least(:once)
    end

    # Il segnale parte da DENTRO il `rescue StandardError` che marca il giro come fallito: se un
    # guasto del trasporto risalisse, un controllo riuscito verrebbe riscritto come fallito, con il
    # nome della classe d'errore al posto del motivo — e il sito porterebbe un `last_error` che non
    # è mai successo. Avvisare chi guarda non è parte dell'esito del controllo.
    it "un guasto del segnale non fa risultare fallito un giro riuscito" do
      allow(Realtime::ThrottledRefresh).to receive(:call).and_raise(IOError.new("cable giù"))
      crawler = crawler_returning(Seo::Crawl::Result.new(pages: [ page_fact ], sitemap_urls: [ "https://sito.test/" ]))

      expect { described_class.call(site:, now:, crawler:) }.not_to raise_error

      expect(site.audits.sole).to be_status_completed
      expect(site.reload.last_error).to be_nil
      expect(site.last_audited_at).to eq(now)
    end

    # E al contrario: un giro fallito deve conservare il SUO motivo, non quello del trasporto.
    it "un guasto del segnale non copre il vero motivo di un giro fallito" do
      allow(Realtime::ThrottledRefresh).to receive(:call).and_raise(IOError.new("cable giù"))
      crawler = crawler_returning(Seo::Crawl::Result.new(error: "timeout"))

      expect { described_class.call(site:, now:, crawler:) }.not_to raise_error

      expect(site.audits.sole).to be_status_failed
      expect(site.audits.sole.error).to eq("timeout")
      expect(site.reload.last_error).to eq("timeout")
    end

    # Un segnale per pagina visitata sarebbe una raffica per un solo esito, e la scheda si
    # ri-chiederebbe decine di volte per mostrare sempre lo stesso stato intermedio.
    it "non manda un segnale per ogni pagina visitata" do
      pagine = 12.times.map { |i| page_fact(path: "/p#{i}") }
      crawler = crawler_returning(Seo::Crawl::Result.new(pages: pagine, sitemap_urls: [ "https://sito.test/" ]))

      expect { described_class.call(site:, now:, crawler:) }.to have_broadcasted_to(stream).at_most(:twice)
    end
  end
end
