# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::RecordAudit, type: :service do
  let(:site) { create(:seo_site, base_url: "https://sito.test") }
  let(:audit) { create(:seo_audit, site:) }
  let(:now) { Time.current.change(usec: 0) }

  def crawled_page(path: "/", **overrides)
    {
      url: "https://sito.test#{path}", path:, status_code: 200, redirect_chain: [],
      response_time_ms: 120, in_sitemap: true, discovered_from: "sitemap",
      blocked_by_robots: false, error: nil, observation: :analyzed,
      attributes: {
        title: "Titolo", meta_description: "Descrizione", canonical_url: "https://sito.test#{path}",
        robots_directives: nil, hreflangs: {}, lang: "it", h1s: [ "Titolo" ], h2_count: 1,
        word_count: 300, jsonld_types: [], images_total: 0, images_without_alt: 0,
        internal_links: [], external_links_count: 0, html_bytes: 10_000, mixed_content: false
      }
    }.merge(overrides)
  end

  def candidate(check_key, url: "https://sito.test/", evidence: { "url" => "https://sito.test/" })
    Seo::Analyze::Candidate.new(check_key:, url:, evidence:)
  end

  def record(pages:, candidates:)
    crawl = Seo::Crawl::Result.new(pages:, sitemap_urls: pages.map { |page| page[:url] })
    described_class.call(site:, audit:, crawl:, candidates:, now:)
  end

  it "scrive le pagine viste con i loro attributi" do
    record(pages: [ crawled_page ], candidates: [])

    page = site.pages.sole
    expect(page.url).to eq("https://sito.test/")
    expect(page.title).to eq("Titolo")
    expect(page.word_count).to eq(300)
    expect(page.last_seen_at).to eq(now)
    expect(page.first_seen_at).to eq(now)
  end

  it "rivedere una pagina non ne cambia la data di prima apparizione" do
    first = 10.days.ago.change(usec: 0)
    site.pages.create!(url: "https://sito.test/", path: "/", first_seen_at: first, last_seen_at: first)

    record(pages: [ crawled_page ], candidates: [])

    page = site.pages.sole
    expect(page.first_seen_at).to eq(first)
    expect(page.last_seen_at).to eq(now)
  end

  it "apre i rilievi nuovi con la gravità del registro e la loro prova" do
    report = record(pages: [ crawled_page ], candidates: [ candidate("missing_h1") ])

    issue = site.issues.sole
    expect(issue.check_key).to eq("missing_h1")
    expect(issue).to be_severity_high
    expect(issue).to be_status_open
    expect(issue.page).to eq(site.pages.sole)
    expect(report.opened.size).to eq(1)
  end

  it "riconferma un rilievo già noto invece di aprirne un altro" do
    record(pages: [ crawled_page ], candidates: [ candidate("missing_h1") ])
    report = record(pages: [ crawled_page ], candidates: [ candidate("missing_h1") ])

    expect(site.issues.count).to eq(1)
    expect(report.opened).to be_empty
    expect(report.reconfirmed.size).to eq(1)
  end

  it "chiude da solo ciò che non c'è più" do
    record(pages: [ crawled_page ], candidates: [ candidate("missing_h1") ])
    report = record(pages: [ crawled_page ], candidates: [])

    issue = site.issues.reload.sole
    expect(issue).to be_status_resolved
    expect(issue.resolved_at).to eq(now)
    expect(report.resolved.size).to eq(1)
  end

  it "non riapre ciò che qualcuno ha deciso di ignorare" do
    record(pages: [ crawled_page ], candidates: [ candidate("missing_h1") ])
    site.issues.sole.update!(status: :ignored)

    record(pages: [ crawled_page ], candidates: [ candidate("missing_h1") ])

    expect(site.issues.reload.sole).to be_status_ignored
  end

  it "non dichiara risolto un rilievo su una pagina che stavolta non ha guardato" do
    altra = crawled_page(path: "/altra")
    record(pages: [ crawled_page, altra ], candidates: [
             candidate("missing_h1"),
             candidate("missing_h1", url: "https://sito.test/altra", evidence: { "url" => "https://sito.test/altra" })
           ])

    # Secondo giro: il tetto di pagine (o un menu cambiato) lascia fuori /altra.
    record(pages: [ crawled_page ], candidates: [ candidate("missing_h1") ])

    ignorata = site.issues.joins(:page).find_by(seo_pages: { path: "/altra" })
    expect(ignorata).to be_status_open
  end

  it "un giro senza pagine non chiude niente: non si è guardato da nessuna parte" do
    record(pages: [ crawled_page ], candidates: [ candidate("missing_h1") ])

    record(pages: [], candidates: [])

    expect(site.issues.reload.sole).to be_status_open
  end

  it "i rilievi d'insieme non hanno una pagina e restano uno solo" do
    site_candidate = Seo::Analyze::Candidate.new(check_key: "duplicate_title", url: nil,
                                                 evidence: { "groups" => [] })
    record(pages: [ crawled_page ], candidates: [ site_candidate ])
    record(pages: [ crawled_page ], candidates: [ site_candidate ])

    issue = site.issues.sole
    expect(issue.page_id).to be_nil
    expect(issue.check_key).to eq("duplicate_title")
  end

  it "chiude il giro contando pagine e rilievi aperti" do
    report = record(pages: [ crawled_page, crawled_page(path: "/due") ],
                    candidates: [ candidate("missing_h1") ])

    expect(audit.reload).to be_status_completed
    expect(audit.finished_at).to eq(now)
    expect(audit.pages_count).to eq(2)
    expect(audit.issues_open_count).to eq(1)
    expect(report.pages_count).to eq(2)
  end

  # CYRA-808 — «risolto» deve voler dire «ho guardato e non c'è più», mai «non sono riuscito a
  # guardare». Il giro che non legge una pagina è il giro in cui l'elenco dei problemi migliora da
  # solo: la bugia più rassicurante che uno strumento di controllo possa raccontare.
  describe "ciò che il giro non è riuscito a leggere" do
    def unread_page(path: "/", observation: :attempted, **overrides)
      crawled_page(path:, observation:, status_code: nil, response_time_ms: nil,
                   error: "timeout", attributes: nil, **overrides)
    end

    it "una pagina andata in timeout non chiude i suoi rilievi" do
      record(pages: [ crawled_page ], candidates: [ candidate("missing_title") ])

      record(pages: [ unread_page ], candidates: [])

      issue = site.issues.reload.sole
      expect(issue).to be_status_open
      expect(issue.resolved_at).to be_nil
    end

    it "una pagina che risponde senza HTML non chiude i rilievi sul contenuto" do
      record(pages: [ crawled_page ], candidates: [ candidate("missing_title") ])

      record(pages: [ crawled_page(observation: :responded, attributes: nil) ], candidates: [])

      expect(site.issues.reload.sole).to be_status_open
    end

    it "una pagina vietata da robots.txt non chiude i rilievi sul contenuto" do
      record(pages: [ crawled_page ], candidates: [ candidate("missing_title") ])

      bloccata = crawled_page(observation: :attempted, blocked_by_robots: true, status_code: nil,
                              response_time_ms: nil, attributes: nil)
      record(pages: [ bloccata ], candidates: [])

      expect(site.issues.reload.sole).to be_status_open
    end

    # L'altra metà della regola: ciò che il giro HA potuto verificare si chiude come sempre. Una
    # pagina che risponde dice con certezza che non è più rotta e che non è più lenta, anche quando
    # il suo contenuto non lo abbiamo letto.
    it "una pagina che risponde chiude i rilievi che dipendono solo dalla risposta" do
      record(pages: [ crawled_page ], candidates: [ candidate("broken_link"), candidate("missing_title") ])

      record(pages: [ crawled_page(observation: :responded, attributes: nil) ], candidates: [])

      per_chiave = site.issues.reload.index_by(&:check_key)
      expect(per_chiave["broken_link"]).to be_status_resolved
      expect(per_chiave["missing_title"]).to be_status_open
    end

    it "un rilievo ignorato resta ignorato anche su una pagina non letta" do
      record(pages: [ crawled_page ], candidates: [ candidate("missing_title") ])
      site.issues.sole.update!(status: :ignored)

      record(pages: [ unread_page ], candidates: [])

      expect(site.issues.reload.sole).to be_status_ignored
    end

    it "quando la pagina torna leggibile e il problema è sparito, il rilievo si chiude" do
      record(pages: [ crawled_page ], candidates: [ candidate("missing_title") ])
      record(pages: [ unread_page ], candidates: [])

      record(pages: [ crawled_page ], candidates: [])

      expect(site.issues.reload.sole).to be_status_resolved
    end

    # I rilievi d'insieme non hanno una pagina: il loro metro è il giro. Nessuna pagina letta vuol
    # dire nessun confronto possibile fra pagine, quindi nessun duplicato da dichiarare scomparso.
    it "senza nemmeno una pagina letta non chiude i rilievi d'insieme" do
      duplicati = Seo::Analyze::Candidate.new(check_key: "duplicate_title", url: nil,
                                              evidence: { "groups" => [] })
      record(pages: [ crawled_page ], candidates: [ duplicati ])

      record(pages: [ unread_page ], candidates: [])

      expect(site.issues.reload.sole).to be_status_open
    end

    it "basta una pagina letta perché i rilievi d'insieme tornino confrontabili" do
      duplicati = Seo::Analyze::Candidate.new(check_key: "duplicate_title", url: nil,
                                              evidence: { "groups" => [] })
      record(pages: [ crawled_page ], candidates: [ duplicati ])

      record(pages: [ unread_page(path: "/altra"), crawled_page ], candidates: [])

      expect(site.issues.reload.find_by(check_key: "duplicate_title")).to be_status_resolved
    end

    it "conta sul giro quante pagine non è riuscito a leggere" do
      report = record(pages: [ crawled_page, unread_page(path: "/altra") ], candidates: [])

      expect(report.unverified_count).to eq(1)
      expect(audit.reload.pages_unverified_count).to eq(1)
    end
  end
end
