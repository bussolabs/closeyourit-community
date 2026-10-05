# frozen_string_literal: true

require "rails_helper"

# L'envelope di lettura della stats API: lo leggono consumatori ESTERNI (bearer di progetto e token
# utente), quindi la forma è il contratto. Un campo che sparisce o che compare qui rompe il grafico
# che qualcuno ha già scritto — e nessun'altra prova guarda questa composizione: gli spec di
# Analytics::Query provano i numeri, non l'involucro.
RSpec.describe Analytics::Snapshot do
  subject(:snapshot) { described_class.call(query:, project:) }

  let(:project) { create(:project) }
  let(:query) { Analytics::Query.new(project_id: project.id, range: "24h", environment: "production") }

  before do
    create(:pageview, project:, path: "/", visitor_hash: "a", occurred_at: 30.minutes.ago,
                      browser: "Chrome", os: "macOS", referrer_host: "google.com")
    create(:pageview, project:, path: "/pricing", visitor_hash: "a", occurred_at: 20.minutes.ago,
                      browser: "Chrome", os: "macOS")
    create(:pageview, project:, path: "/pricing", visitor_hash: "b", occurred_at: 10.minutes.ago,
                      browser: "Firefox", os: "Linux")
  end

  it "porta le sezioni dichiarate, nessuna di meno" do
    expect(snapshot.keys).to match_array(%i[summary comparison timeseries top_pages top_referrers
                                            channels entry_pages exit_pages breakdowns goals])
  end

  it "il riepilogo unisce traffico e metriche di sessione in un blocco solo" do
    expect(snapshot[:summary])
      .to include(pageviews: 3, visitors: 2, sessions: 2, views_per_visit: 1.5, bounce_rate: 50)
    expect(snapshot[:summary].keys)
      .to match_array(%i[pageviews visitors bounce_rate visit_duration views_per_visit sessions realtime])
  end

  # `realtime` conta chi c'è ADESSO, su una finestra sua: le tre visite del setup sono già fuori.
  it "il conteggio in tempo reale guarda solo la finestra corta, non tutto il periodo" do
    expect(snapshot[:summary][:realtime]).to eq(0)

    create(:pageview, project:, visitor_hash: "c", occurred_at: 1.minute.ago)
    expect(described_class.call(query:, project:)[:summary]).to include(realtime: 1, pageviews: 4)
  end

  it "il confronto porta solo i due periodi, senza i campi di servizio del Query" do
    expect(snapshot[:comparison].keys).to eq(%i[current previous])
    expect(snapshot[:comparison][:current]).to eq(pageviews: 3, visitors: 2)
    expect(snapshot[:comparison][:previous]).to eq(pageviews: 0, visitors: 0)
  end

  # Il commento sul service lo chiama «wire congelato»: `:at` serve all'asse X della dashboard
  # interna e resta dentro. Se un giorno passasse di qui, chi legge la serie si troverebbe una
  # chiave in più senza averla chiesta.
  it "la serie temporale porta solo visite e visitatori: l'istante del blocco resta interno" do
    expect(snapshot[:timeseries].size).to eq(Analytics::Pageview::BUCKETS["24h"][:count])
    expect(snapshot[:timeseries]).to all(match(pageviews: an_instance_of(Integer),
                                               visitors: an_instance_of(Integer)))
    expect(snapshot[:timeseries].sum { |bucket| bucket[:pageviews] }).to eq(3)
  end

  it "le classifiche arrivano già ordinate dal Query" do
    expect(snapshot[:top_pages].first).to eq(path: "/pricing", pageviews: 2, visitors: 2)
    expect(snapshot[:top_referrers]).to eq([ { referrer_host: "google.com", visitors: 1 } ])
    expect(snapshot[:entry_pages].map { |row| row[:path] }).to include("/")
    expect(snapshot[:exit_pages].map { |row| row[:path] }).to include("/pricing")
    expect(snapshot[:channels].map { |row| row[:value] }).to include("Direct")
  end

  it "espone esattamente le dimensioni dichiarate, non tutte quelle interrogabili" do
    expect(snapshot[:breakdowns].keys).to eq(described_class::BREAKDOWN_PROPERTIES)
    expect(snapshot[:breakdowns]["browser"]).to eq([ { value: "Chrome", visitors: 1 },
                                                     { value: "Firefox", visitors: 1 } ])
    # `screen_class` e le utm meno usate restano fuori: il subset è una scelta, non una dimenticanza.
    expect(snapshot[:breakdowns].keys).not_to include("screen_class", "browser_version")
  end

  describe "le conversioni" do
    it "seguono l'ordine dei goal e dicono il bersaglio nella forma del loro tipo" do
      create(:analytics_goal, project:, display_name: "Zeta pagina", path_pattern: "/pricing")
      create(:analytics_goal, :custom_event, project:, display_name: "Alfa evento", event_name: "Signup")

      expect(snapshot[:goals].map { |goal| goal[:display_name] }).to eq([ "Alfa evento", "Zeta pagina" ])
      expect(snapshot[:goals].first).to include(kind: "custom_event", target: "Signup")
      expect(snapshot[:goals].last).to include(kind: "pageview_path", target: "/pricing")
      expect(snapshot[:goals].last[:conversions])
        .to eq(unique_conversions: 2, total_conversions: 2, conversion_rate: 100.0)
    end

    it "senza goal la sezione c'è ed è vuota: nessun consumatore deve gestire l'assenza della chiave" do
      expect(snapshot[:goals]).to eq([])
    end
  end
end
