# frozen_string_literal: true

require "rails_helper"

# CYRA-400 — «Occorrenze recenti» era la sezione più grande della pagina ed era quella che diceva
# meno: quindici righe con lo stesso momento, lo stesso ambiente e lo stesso rilascio ripetuto per
# esteso, dove l'unica cosa che cambiava era l'identificativo dell'evento. Ora se ne mostrano cinque,
# i valori costanti sull'INTERA pagina si dicono una volta sola in un riepilogo, e le altre stanno
# dietro un comando.
RSpec.describe "Member::Monitoring::ErrorGroups occorrenze", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:group) { create(:error_group, project:) }
  let(:collapsed) { Monitoring::Constants::OCCURRENCES_COLLAPSED }
  let(:per_page) { Monitoring::Constants::OCCURRENCES_PER_PAGE }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def rows = response.body.scan('data-test="occurrence-row"').size
  def doc = Nokogiri::HTML(response.body)
  def headers = doc.css("[data-test='occurrences-table'] th").map { |th| th.text.strip }

  # n occorrenze tutte identiche fra loro salvo l'istante: è il caso reale del rilievo.
  def create_events(count, **attrs)
    Array.new(count) { |i| create(:error_event, group:, project:, occurred_at: (i + 1).minutes.ago, **attrs) }
  end

  describe "quante occorrenze si mostrano" do
    it "ne mostra cinque e tiene le altre dietro un comando" do
      create_events(per_page)

      get member_monitoring_error_group_path(group)

      expect(rows).to eq(collapsed)
      expect(doc.at_css("[data-test='occurrences-show-all']")).to be_present
      expect(response.body).to include(
        I18n.t("member.monitoring.occurrences_count", count: per_page, shown: collapsed)
      )
    end

    it "il comando apre tutte le occorrenze della pagina e offre di richiuderle" do
      create_events(per_page)
      get member_monitoring_error_group_path(group)

      get doc.at_css("[data-test='occurrences-show-all']")["href"]

      expect(rows).to eq(per_page)
      expect(doc.at_css("[data-test='occurrences-show-less']")).to be_present
      expect(doc.at_css("[data-test='occurrences-show-all']")).to be_nil
    end

    it "il comando preserva filtri, intervallo e pagina" do
      # pagina 2 deve avere più righe del limite, altrimenti non c'è niente da aprire
      create_events(per_page + collapsed + 1, environment: "staging")
      create(:error_event, group:, project:, environment: "production", occurred_at: 1.second.ago)

      get member_monitoring_error_group_path(group, environment: [ "staging" ], range: "7d", page: 2)
      href = doc.at_css("[data-test='occurrences-show-all']")["href"]

      expect(href).to include("environment", "staging", "range=7d", "page=2", "occurrences=all")
    end

    it "con meno occorrenze del limite non offre nessun comando" do
      create_events(collapsed)

      get member_monitoring_error_group_path(group)

      expect(rows).to eq(collapsed)
      expect(doc.at_css("[data-test='occurrences-show-all']")).to be_nil
      expect(doc.at_css("[data-test='occurrences-show-less']")).to be_nil
    end

    it "i pannelli di dettaglio seguono le occorrenze mostrate: quelle nascoste non pesano sulla pagina" do
      events = create_events(per_page)

      get member_monitoring_error_group_path(group)

      panel_ids = doc.css("[data-test='occurrence-panel']").map { |panel| panel["data-panel-id"] }
      expect(panel_ids).to match_array(events.first(collapsed).map { |event| event.id.to_s })
    end
  end

  describe "riepilogo dei valori costanti" do
    it "raccoglie in una riga sola i valori uguali su tutte le occorrenze della pagina" do
      create_events(per_page, environment: "staging", release: "c543d36", level: :warning)

      get member_monitoring_error_group_path(group)

      summary = doc.at_css("[data-test='occurrences-summary']")
      expect(summary).to be_present
      expect(summary.text).to include(I18n.t("member.monitoring.occurrences_summary", count: per_page))
      expect(summary.text).to include("staging", "c543d36", I18n.t("member.monitoring.levels.warning"))
    end

    it "toglie dalla tabella le colonne che il riepilogo ha già detto" do
      create_events(per_page, environment: "staging", release: "c543d36", level: :warning)

      get member_monitoring_error_group_path(group)

      expect(headers).to include(I18n.t("member.monitoring.col_when"), I18n.t("member.monitoring.col_event"))
      expect(headers).not_to include(I18n.t("member.monitoring.col_environment"),
                                     I18n.t("member.monitoring.col_release"),
                                     I18n.t("member.monitoring.col_level"))
    end

    it "un valore che cambia resta in colonna, anche se a cambiarlo è una riga non mostrata" do
      create_events(collapsed, environment: "staging", release: "c543d36")
      # più vecchia di tutte → resta dietro il comando, ma la pagina la contiene: il riepilogo non
      # può dichiarare «tutte in staging» per una pagina dove una non lo è.
      create(:error_event, group:, project:, environment: "production", release: "c543d36",
             occurred_at: 1.hour.ago)

      get member_monitoring_error_group_path(group)

      expect(headers).to include(I18n.t("member.monitoring.col_environment"))
      expect(headers).not_to include(I18n.t("member.monitoring.col_release"))
      expect(doc.at_css("[data-test='occurrences-summary']").text).not_to include("staging")
    end

    it "guarda la pagina mostrata, non l'intero gruppo" do
      create_events(per_page, environment: "staging")
      create(:error_event, group:, project:, environment: "production", occurred_at: 1.day.ago)

      get member_monitoring_error_group_path(group)

      # la production è in pagina 2: la pagina 1 è tutta staging e lo dichiara solo per sé
      summary = doc.at_css("[data-test='occurrences-summary']")
      expect(summary.text).to include("staging", I18n.t("member.monitoring.occurrences_summary", count: per_page))
    end

    it "un valore assente su tutte non diventa un riepilogo: la colonna resta col suo trattino" do
      create_events(per_page, release: nil)

      get member_monitoring_error_group_path(group)

      expect(doc.at_css("[data-test='occurrences-summary-release']")).to be_nil
      expect(headers).to include(I18n.t("member.monitoring.col_release"))
    end

    it "con una sola occorrenza non c'è niente da riassumere" do
      create_events(1)

      get member_monitoring_error_group_path(group)

      expect(doc.at_css("[data-test='occurrences-summary']")).to be_nil
      expect(headers).to include(I18n.t("member.monitoring.col_environment"))
    end
  end

  # CYRA-924 — every column sorts (C9); the first row is the one opened on the side.
  describe "sort" do
    it "sorts by release both ways and offers every column" do
      create(:error_event, group:, project:, occurred_at: 1.minute.ago, release: "zeta-9", environment: "production", level: :error)
      create(:error_event, group:, project:, occurred_at: 2.minutes.ago, release: "alpha-1", environment: "staging", level: :warning)

      table = -> { doc.at_css("[data-test='occurrences-table']").to_html }
      get member_monitoring_error_group_path(group, sort: "release")
      expect(table.call.index("alpha-1")).to be < table.call.index("zeta-9")
      get member_monitoring_error_group_path(group, sort: "-release")
      expect(table.call.index("zeta-9")).to be < table.call.index("alpha-1")
      %w[when environment release level event].each { |key| expect(response.body).to include("sort=#{key}").or include("sort=-#{key}") }
    end
  end

  # CYRA-924 — the bar holds no count (C63): on a detail page the list count sits beside the section title.
  describe "the list count" do
    it "sits beside the section title, not in the bar" do
      create_events(2)

      get member_monitoring_error_group_path(group)

      label = I18n.t("member.monitoring.occurrences_count", count: 2, shown: 2)
      expect(doc.at_css("[data-test='occurrences-count']").text.strip).to eq(label)
      expect(doc.at_css("[data-test='occurrences-toolbar']").text).not_to include(label)
    end
  end
end
