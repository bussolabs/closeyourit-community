# frozen_string_literal: true

require "rails_helper"

# CYRA-562 — il grafico in cima al dettaglio errore disegnava sempre TUTTE le occorrenze del gruppo,
# qualunque filtro fosse acceso sotto: restringendo a un ambiente senza occorrenze si leggeva
# «24h, 48 blocchi, picco 84» con le colonne piene, e 190 pixel più in basso la stessa pagina
# scriveva due volte «Nessun evento conservato per questo errore». Il grafico è la prima cosa che si
# guarda per capire se un errore è in corso: sull'insieme scelto diceva il falso.
RSpec.describe "Member::Monitoring::ErrorGroups grafico", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:group) { create(:error_group, project:) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def doc = Nokogiri::HTML(response.body)
  def chart = doc.at_css("[data-test='error-buckets']")
  def no_results = doc.at_css("[data-test='error-chart-no-results']")

  describe "il grafico legge lo stesso insieme della tabella" do
    it "conta solo le occorrenze dell'ambiente scelto" do
      create_list(:error_event, 3, group:, project:, environment: "production", occurred_at: 5.minutes.ago)
      create(:error_event, group:, project:, environment: "staging", occurred_at: 5.minutes.ago)

      get member_monitoring_error_group_path(group, environment: [ "staging" ])

      expect(chart).to be_present
      expect(response.body).to include(I18n.t("member.monitoring.chart_peak", count: 1))
      expect(response.body).not_to include(I18n.t("member.monitoring.chart_peak", count: 4))
    end

    it "conta solo le occorrenze del rilascio scelto" do
      create_list(:error_event, 2, group:, project:, release: "v1.0.0", occurred_at: 5.minutes.ago)
      create(:error_event, group:, project:, release: "v2.0.0", occurred_at: 5.minutes.ago)

      get member_monitoring_error_group_path(group, release: [ "v2.0.0" ])

      expect(response.body).to include(I18n.t("member.monitoring.chart_peak", count: 1))
    end

    it "conta solo le occorrenze del livello scelto" do
      create_list(:error_event, 2, group:, project:, level: :error, occurred_at: 5.minutes.ago)
      create(:error_event, group:, project:, level: :warning, occurred_at: 5.minutes.ago)

      get member_monitoring_error_group_path(group, level: [ "warning" ])

      expect(response.body).to include(I18n.t("member.monitoring.chart_peak", count: 1))
    end

    it "senza filtri disegna tutte le occorrenze del gruppo" do
      create_list(:error_event, 3, group:, project:, environment: "production", occurred_at: 5.minutes.ago)
      create(:error_event, group:, project:, environment: "staging", occurred_at: 5.minutes.ago)

      get member_monitoring_error_group_path(group)

      expect(chart).to be_present
      expect(response.body).to include(I18n.t("member.monitoring.chart_peak", count: 4))
    end

    # Il blocco cliccato NASCE dal grafico: restringere anche il grafico a quella finestra lascerebbe
    # una barra sola e toglierebbe il modo di tornare indietro cliccando un altro blocco.
    it "il blocco cliccato sull'istogramma filtra le occorrenze ma non il grafico" do
      create_list(:error_event, 3, group:, project:, occurred_at: 5.minutes.ago)
      create(:error_event, group:, project:, occurred_at: 3.hours.ago)

      get member_monitoring_error_group_path(group, from: 10.minutes.ago.iso8601(6), to: 1.minute.ago.iso8601(6))

      expect(chart).to be_present
      expect(response.body).to include(I18n.t("member.monitoring.chart_peak", count: 3))
    end
  end

  describe "quando i filtri non lasciano occorrenze" do
    before do
      create_list(:error_event, 4, group:, project:, environment: "production", occurred_at: 5.minutes.ago)
    end

    it "non disegna nessuna colonna e lo dichiara" do
      get member_monitoring_error_group_path(group, environment: [ "staging" ])

      expect(chart).to be_nil
      expect(no_results).to be_present
      expect(response.body).not_to include(I18n.t("member.monitoring.chart_peak", count: 4))
    end

    it "offre di togliere i filtri tornando alla stessa pagina senza di essi" do
      get member_monitoring_error_group_path(group, environment: [ "staging" ], range: "7d")

      href = no_results.at_css("a")["href"]
      expect(href).to include("range=7d")
      expect(href).not_to include("staging")

      get href

      expect(chart).to be_present
      expect(response.body).to include(I18n.t("member.monitoring.chart_peak", count: 4))
    end

    # La riga «48 blocchi» descrive blocchi che non si stanno più disegnando: sparisce con loro.
    it "non dichiara più il numero di blocchi disegnati" do
      get member_monitoring_error_group_path(group, environment: [ "staging" ])

      expect(response.body).not_to include(I18n.t("member.monitoring.timeline_sub", range: "24h", count: 48))
    end
  end

  describe "quando non c'è nessuna occorrenza e nessun filtro" do
    # Niente da togliere: offrire «azzera i filtri» dove filtri non ce ne sono manderebbe a sbattere.
    it "dice che nel periodo non c'è nessuna occorrenza, senza offrire di togliere filtri" do
      get member_monitoring_error_group_path(group)

      expect(chart).to be_nil
      expect(no_results).to be_nil
      expect(doc.at_css("[data-test='error-chart-empty']")).to be_present
    end
  end
end
