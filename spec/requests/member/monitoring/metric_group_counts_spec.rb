# frozen_string_literal: true

require "rails_helper"

# CYRA-815 — le pill in cima all'elenco delle prestazioni e l'elenco stesso devono parlare dello
# STESSO insieme. Prima il totale seguiva i filtri e le altre quattro voci (query lente, metodi
# lenti, problemi, tempo) contavano tutta la storia dell'organizzazione: si leggeva «Gruppi: 19»
# accanto a «Query lente: 1.900», con lo stesso aspetto, e sembrava un guasto.
#
# Il confine è lo stesso di CYRA-383 sugli errori: le pill contano sullo scope filtrato MENO la
# dimensione che rappresentano (lì lo stato, qui la categoria e il tipo di problema), così la loro
# somma È il totale e ognuna è un filtro applicabile con un clic.
#
# Il tempo resta l'eccezione dichiarata: `duration_total_ms` è cumulativo dalla nascita del gruppo,
# quindi i filtri scelgono QUALI gruppi sommare ma il numero che ne esce è il loro costo da sempre,
# non la somma degli eventi nel periodo. Non è nascondibile: è scritto nell'etichetta.
RSpec.describe "Prestazioni — le pill seguono i filtri (CYRA-815)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org, name: "Storefront") }
  let(:other_project) { create(:project, organization: org, name: "Backoffice") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # The value written in a count (the Mono span). With `href` the count is a link, so the node
  # changes tag but not structure.
  def stat(test_id)
    node = Nokogiri::HTML(response.body).at_css(%([data-test="#{test_id}"]))
    node && node.at_css("span.font-mono").text.strip
  end

  def stats
    { groups: stat("stat-groups"), slow_queries: stat("stat-slow-queries"),
      slow_methods: stat("stat-slow-methods"), issues: stat("stat-performance-issues"),
      duration: stat("stat-total-duration") }
  end

  describe "il periodo (Scenario 1)" do
    before do
      create(:metric_group, project:, fingerprint: "fresh-query", title: "FreshQuery",
                            kind: :slow_query, last_seen_at: 5.minutes.ago, duration_total_ms: 1_000.0)
      create(:metric_group, project:, fingerprint: "old-query", title: "OldQuery",
                            kind: :slow_query, last_seen_at: 10.days.ago, duration_total_ms: 90_000_000.0)
      create(:metric_group, :slow_method, project:, fingerprint: "old-method", title: "OldMethod",
                                          last_seen_at: 10.days.ago, duration_total_ms: 5_000.0)
    end

    it "a trenta minuti tutte le pill descrivono la finestra, non la storia intera" do
      sign_in(owner)
      get member_monitoring_metric_groups_path, params: { range: "30m" }

      expect(stats).to include(groups: "1", slow_queries: "1", slow_methods: "0", issues: "0")
    end

    it "allargando a trenta giorni i numeri crescono TUTTI insieme, non solo il totale" do
      sign_in(owner)
      get member_monitoring_metric_groups_path, params: { range: "30d" }

      expect(stats).to include(groups: "3", slow_queries: "2", slow_methods: "1", issues: "0")
    end

    it "anche il tempo segue il periodo: i gruppi fuori finestra non pesano più" do
      sign_in(owner)
      get member_monitoring_metric_groups_path, params: { range: "30m" }
      stretto = stat("stat-total-duration")

      get member_monitoring_metric_groups_path, params: { range: "30d" }
      largo = stat("stat-total-duration")

      expect(stretto).to eq("1s")
      expect(largo).not_to eq(stretto)
    end
  end

  describe "gli altri filtri dell'elenco" do
    it "il progetto restringe tutte le pill" do
      sign_in(owner)
      create(:metric_group, project:, fingerprint: "here", title: "HereQuery", kind: :slow_query)
      create(:metric_group, project: other_project, fingerprint: "there", title: "ThereQuery", kind: :slow_query)

      get member_monitoring_metric_groups_path, params: { project_id: [ project.id ] }

      expect(stats).to include(groups: "1", slow_queries: "1")
    end

    it "la ricerca restringe tutte le pill" do
      sign_in(owner)
      create(:metric_group, project:, fingerprint: "widgets", title: "SELECT * FROM widgets", kind: :slow_query)
      create(:metric_group, :slow_method, project:, fingerprint: "checkout", title: "Checkout#total")

      get member_monitoring_metric_groups_path, params: { q: "widgets" }

      expect(stats).to include(groups: "1", slow_queries: "1", slow_methods: "0")
    end

    it "lo stato del triage restringe tutte le pill" do
      sign_in(owner)
      create(:metric_group, project:, fingerprint: "open-one", title: "OpenQuery",
                            kind: :slow_query, status: :unresolved)
      create(:metric_group, project:, fingerprint: "done-one", title: "DoneQuery",
                            kind: :slow_query, status: :resolved)

      get member_monitoring_metric_groups_path, params: { status: [ "resolved" ] }

      expect(stats).to include(groups: "1", slow_queries: "1")
    end

    it "«solo non promossi» restringe tutte le pill" do
      sign_in(owner)
      ticket = create(:ticket, project:, organization: org)
      create(:metric_group, project:, fingerprint: "libero", title: "FreeQuery", kind: :slow_query)
      create(:metric_group, project:, fingerprint: "promosso", title: "PromotedQuery",
                            kind: :slow_query, ticket: ticket)

      get member_monitoring_metric_groups_path, params: { open: "1" }

      expect(stats).to include(groups: "1", slow_queries: "1")
    end
  end

  describe "la categoria è la dimensione che le pill rappresentano" do
    before do
      create(:metric_group, project:, fingerprint: "q1", title: "QueryOne", kind: :slow_query)
      create(:metric_group, :slow_method, project:, fingerprint: "m1", title: "MethodOne")
      create(:metric_group, :performance_issue, project:, fingerprint: "p1", title: "IssueOne")
    end

    it "filtrando per categoria le pill continuano a contare tutte le categorie" do
      sign_in(owner)
      get member_monitoring_metric_groups_path, params: { kind: [ "slow_query" ] }

      expect(response.body).to include("QueryOne")
      expect(response.body).not_to include("MethodOne")
      expect(stats).to include(groups: "3", slow_queries: "1", slow_methods: "1", issues: "1")
    end

    it "la somma delle tre categorie è il totale" do
      sign_in(owner)
      get member_monitoring_metric_groups_path

      somma = %i[slow_queries slow_methods issues].sum { |k| stats.fetch(k).to_i }
      expect(somma).to eq(stats.fetch(:groups).to_i)
    end

    it "ogni pill è un filtro applicabile con un clic e quella scelta è accesa" do
      sign_in(owner)
      get member_monitoring_metric_groups_path, params: { kind: [ "slow_query" ] }

      pill = Nokogiri::HTML(response.body).at_css('[data-test="stat-slow-queries"]')
      expect(pill.name).to eq("a")
      expect(pill["href"]).to include("kind=slow_query")
      expect(pill["aria-current"]).to eq("true")
      # Il totale riporta all'insieme intero togliendo la categoria.
      expect(Nokogiri::HTML(response.body).at_css('[data-test="stat-groups"]')["href"]).not_to include("kind=")
    end

    # Revisione CYRA-815 — «Gruppi» acceso vuol dire «stai guardando tutto»: con due categorie
    # insieme, o col solo tipo di problema, l'elenco è ristretto e nessuna delle tre pill è sola.
    # Accendere il totale prometterebbe un elenco più largo di quello che si vede.
    it "con due categorie insieme nessuna pill è accesa, nemmeno il totale" do
      sign_in(owner)
      get member_monitoring_metric_groups_path, params: { kind: %w[slow_query slow_method] }

      doc = Nokogiri::HTML(response.body)
      %w[stat-groups stat-slow-queries stat-slow-methods stat-performance-issues].each do |id|
        expect(doc.at_css(%([data-test="#{id}"]))["aria-current"]).to be_nil
      end
    end

    it "col solo tipo di problema selezionato il totale non è acceso" do
      sign_in(owner)
      get member_monitoring_metric_groups_path, params: { subtype: [ "n_plus_one" ] }

      expect(Nokogiri::HTML(response.body).at_css('[data-test="stat-groups"]')["aria-current"]).to be_nil
    end

    it "senza filtri di categoria il totale è acceso" do
      sign_in(owner)
      get member_monitoring_metric_groups_path

      expect(Nokogiri::HTML(response.body).at_css('[data-test="stat-groups"]')["aria-current"]).to eq("true")
    end

    it "cambiando categoria dalla pill il tipo di problema non resta appeso (elenco vuoto silenzioso)" do
      sign_in(owner)
      get member_monitoring_metric_groups_path, params: { subtype: [ "n_plus_one" ] }

      href = Nokogiri::HTML(response.body).at_css('[data-test="stat-slow-queries"]')["href"]
      expect(href).to include("kind=slow_query")
      expect(href).not_to include("subtype")
    end
  end

  describe "il tempo dice di che tempo parla" do
    it "l'etichetta e la spiegazione dicono che è il costo storico dei gruppi scelti" do
      owner.update!(locale: "it")
      sign_in(owner)
      create(:metric_group, project:, fingerprint: "costoso", title: "CostlyQuery", duration_total_ms: 5_000.0)

      get member_monitoring_metric_groups_path

      pill = Nokogiri::HTML(response.body).at_css('[data-test="stat-total-duration"]')
      expect(pill.text).to include(I18n.t("member.metrics.stat_total_duration", locale: :it))
      expect(pill["title"]).to eq(I18n.t("member.metrics.stat_total_duration_title", locale: :it))
      expect(I18n.t("member.metrics.stat_total_duration", locale: :it)).to match(/storic/i)
    end

    it "somma solo i gruppi filtrati, non tutta l'organizzazione" do
      sign_in(owner)
      create(:metric_group, project:, fingerprint: "dentro", title: "InsideQuery", duration_total_ms: 2_000.0)
      create(:metric_group, project: other_project, fingerprint: "fuori", title: "OutsideQuery",
                            duration_total_ms: 90_000_000.0)

      get member_monitoring_metric_groups_path, params: { project_id: [ project.id ] }

      expect(stat("stat-total-duration")).to eq("2s")
    end
  end

  describe "quando non passa niente" do
    it "le pill vanno a zero e il tempo è un trattino, non «0ms»" do
      sign_in(owner)
      create(:metric_group, project:, fingerprint: "vecchio", title: "OldQuery",
                            last_seen_at: 10.days.ago, duration_total_ms: 4_000.0)

      get member_monitoring_metric_groups_path, params: { range: "30m" }

      expect(stats).to eq(groups: "0", slow_queries: "0", slow_methods: "0", issues: "0", duration: "—")
      expect(response.body).to include('data-test="metrics-no-match"')
    end
  end

  # DoD — l'aggiornamento automatico della pagina è un page-refresh Turbo morph: il browser
  # ri-fetcha QUESTO indirizzo, filtri compresi, e nessun broadcast spedisce numeri già cotti. Se
  # qualcuno reintroducesse un ricalcolo org-wide nel path del refresh, la seconda lettura
  # divergerebbe dalla prima.
  describe "dopo l'aggiornamento automatico" do
    it "il refresh ripassa dallo stesso indirizzo filtrato e i numeri non tornano globali" do
      sign_in(owner)
      create(:metric_group, project:, fingerprint: "recente", title: "FreshQuery", last_seen_at: 2.minutes.ago)
      create(:metric_group, project:, fingerprint: "antico", title: "OldQuery", last_seen_at: 20.days.ago)

      get member_monitoring_metric_groups_path, params: { range: "30m" }
      prima = stats

      # Il campione nuovo fa scattare il refresh: il viewer ri-chiede la pagina come l'aveva.
      create(:metric_group, project:, fingerprint: "nuovissimo", title: "NewestQuery", last_seen_at: 1.minute.ago)
      get member_monitoring_metric_groups_path, params: { range: "30m" }

      expect(prima).to include(groups: "1", slow_queries: "1")
      expect(stats).to include(groups: "2", slow_queries: "2")
    end
  end
end
