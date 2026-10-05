# frozen_string_literal: true

require "rails_helper"

# CYRA-340 — il periodo di tempo, uno solo per errori, prestazioni e log. Prima erano tre modi
# diversi in tre pagine attaccate: nelle prestazioni non si poteva scegliere affatto, nei log si
# scrivevano due date complete a mano, nel dettaglio c'erano le scelte rapide. Durante un guasto si
# perdeva l'arco di tempo a ogni cambio di pagina.
RSpec.describe "Member::Monitoring periodo condiviso", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  # Le tre pagine dell'area di controllo, con la colonna del tempo su cui ciascuna filtra.
  PAGES = {
    "errori" => :member_monitoring_error_groups_path,
    "prestazioni" => :member_monitoring_metric_groups_path,
    "log" => :member_monitoring_log_entries_path
  }.freeze

  def html = Nokogiri::HTML(response.body)

  describe "lo stesso selettore, nella stessa posizione" do
    # Una riga per pagina: la barra dei filtri (e con lei il selettore) non si rende sullo stato di
    # primo giorno, dove non c'è ancora niente da restringere.
    before do
      create(:error_group, project:, last_seen_at: 1.hour.ago)
      create(:metric_group, project:, last_seen_at: 1.hour.ago)
      create(:log_entry, project:, occurred_at: 1.hour.ago)
    end

    # CYRA-883, CYRA-924: on every list the range is a chip of the Filters menu, never pills.
    PAGES.each do |nome, helper|
      it "#{nome}: the range is a Filters chip with the same presets" do
        get public_send(helper)

        pagina = html
        expect(pagina.at_css('[data-test="time-range"]')).to be_nil
        expect(pagina.at_css('[data-test="filter-menu-range"]')).to be_present
        values = pagina.css("[data-test='filter-chip-range'] button[data-value]").map { |b| b["data-value"] }
        expect(values).to eq([ "", "30m", "7d", "30d" ])
        expect(pagina.at_css("[data-test='filter-chip-range'] input[type='datetime-local'][name='from']")).to be_present
      end
    end
  end

  describe "guardare le ultime ventiquattro ore ovunque (scenario 1)" do
    it "gli errori visti da più di un giorno restano fuori, e con sette giorni tornano" do
      create(:error_group, project:, title: "ErroreRecente", last_seen_at: 2.hours.ago)
      create(:error_group, project:, title: "ErroreVecchio", last_seen_at: 3.days.ago)

      get member_monitoring_error_groups_path
      expect(response.body).to include("ErroreRecente")
      expect(response.body).not_to include("ErroreVecchio")

      get member_monitoring_error_groups_path(range: "7d")
      expect(response.body).to include("ErroreVecchio")
    end

    it "le prestazioni, che prima non si potevano restringere affatto, ora seguono lo stesso periodo" do
      create(:metric_group, project:, title: "QueryRecente", last_seen_at: 2.hours.ago)
      create(:metric_group, project:, title: "QueryVecchia", last_seen_at: 3.days.ago)

      get member_monitoring_metric_groups_path
      expect(response.body).to include("QueryRecente")
      expect(response.body).not_to include("QueryVecchia")

      get member_monitoring_metric_groups_path(range: "30d")
      expect(response.body).to include("QueryVecchia")
    end

    it "i log seguono lo stesso periodo, senza scrivere due date a mano" do
      create(:log_entry, project:, message: "LogRecente", occurred_at: 2.hours.ago)
      create(:log_entry, project:, message: "LogVecchio", occurred_at: 3.days.ago)

      get member_monitoring_log_entries_path
      expect(response.body).to include("LogRecente")
      expect(response.body).not_to include("LogVecchio")
    end

    it "mezz'ora è una scelta rapida vera anche sugli elenchi" do
      create(:error_group, project:, title: "UltimoMinuto", last_seen_at: 1.minute.ago)
      create(:error_group, project:, title: "DueOreFa", last_seen_at: 2.hours.ago)

      get member_monitoring_error_groups_path(range: "30m")

      expect(response.body).to include("UltimoMinuto")
      expect(response.body).not_to include("DueOreFa")
    end
  end

  describe "il periodo scelto resta mentre si gira fra le pagine" do
    it "scelto sugli errori, vale anche su prestazioni e log" do
      create(:metric_group, project:, title: "QueryDiTreGiorniFa", last_seen_at: 3.days.ago)
      create(:log_entry, project:, message: "LogDiTreGiorniFa", occurred_at: 3.days.ago)

      get member_monitoring_error_groups_path(range: "7d")

      get member_monitoring_metric_groups_path
      expect(response).to redirect_to(member_monitoring_metric_groups_path(range: "7d"))
      follow_redirect!
      expect(response.body).to include("QueryDiTreGiorniFa")

      get member_monitoring_log_entries_path
      follow_redirect!
      expect(response.body).to include("LogDiTreGiorniFa")
    end

    it "il periodo ricordato torna nell'indirizzo, così il collegamento condiviso mostra gli stessi dati" do
      get member_monitoring_error_groups_path(range: "30d")
      get member_monitoring_error_groups_path

      expect(response).to redirect_to(member_monitoring_error_groups_path(range: "30d"))
    end

    it "il periodo ricordato non butta via gli altri filtri già nell'indirizzo" do
      get member_monitoring_error_groups_path(range: "7d")
      get member_monitoring_error_groups_path(status: [ "resolved" ])

      expect(response).to redirect_to(member_monitoring_error_groups_path(status: [ "resolved" ], range: "7d"))
    end

    it "l'indirizzo comanda: un collegamento con un periodo dentro vince su quello ricordato" do
      create(:error_group, project:, title: "ErroreDiTreGiorniFa", last_seen_at: 3.days.ago)

      get member_monitoring_error_groups_path(range: "30d")
      get member_monitoring_error_groups_path(range: "30m")

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("ErroreDiTreGiorniFa")
    end

    it "chi non ha mai scelto niente atterra sul predefinito senza rimbalzi" do
      get member_monitoring_metric_groups_path

      expect(response).to have_http_status(:ok)
    end
  end

  describe "il periodo resta valido aprendo il dettaglio di una riga" do
    it "l'errore si apre sullo stesso arco di tempo dell'elenco" do
      gruppo = create(:error_group, project:, title: "ErroreDaAprire", last_seen_at: 2.hours.ago)

      get member_monitoring_error_groups_path(range: "7d")

      collegamento = html.at_css(%([data-test="error-group-link-#{gruppo.id}"]))["href"]
      expect(collegamento).to include("range=7d")
    end

    it "la prestazione si apre sullo stesso arco di tempo dell'elenco" do
      gruppo = create(:metric_group, project:, title: "SELECT quella lenta", last_seen_at: 2.hours.ago)

      get member_monitoring_metric_groups_path(range: "30d")

      collegamento = html.at_css(%([data-test="metric-group-link-#{gruppo.id}"]))["href"]
      expect(collegamento).to include("range=30d")
    end

    it "il dettaglio disegna il grafico sul periodo che gli arriva dall'elenco" do
      gruppo = create(:error_group, project:, last_seen_at: 1.hour.ago)

      get member_monitoring_error_group_path(gruppo, range: "7d")

      expect(html.at_css('[data-test="range-7d"]')["class"]).to include("bg-white")
    end
  end

  describe "le date scritte a mano restano possibili sotto «Personalizzato»" do
    it "i due campi compaiono solo lì, e restringono davvero" do
      create(:log_entry, project:, message: "DentroLaFinestra", occurred_at: Time.zone.local(2026, 7, 9, 14, 5))
      create(:log_entry, project:, message: "FuoriDallaFinestra", occurred_at: Time.zone.local(2026, 7, 9, 16, 0))

      get member_monitoring_log_entries_path

      # CYRA-985: the two dates always sit in the range menu, empty until a custom range is set.
      expect(html.at_css('[data-test="logs-range-from"]')["value"]).to be_blank

      get member_monitoring_log_entries_path(range: "custom", from: "2026-07-09T14:00", to: "2026-07-09T14:10")

      expect(response.body).to include("DentroLaFinestra")
      expect(response.body).not_to include("FuoriDallaFinestra")
      expect(html.at_css('[data-test="logs-range-from"]')["value"]).to eq("2026-07-09T14:00")
    end

    it "una finestra scritta a mano vale anche su errori e prestazioni" do
      create(:error_group, project:, title: "ErroreNellaFinestra", last_seen_at: Time.zone.local(2026, 7, 9, 14, 5))
      create(:error_group, project:, title: "ErroreFuori", last_seen_at: Time.zone.local(2026, 7, 10, 14, 5))

      get member_monitoring_error_groups_path(range: "custom", from: "2026-07-09T14:00", to: "2026-07-09T14:10")

      expect(response.body).to include("ErroreNellaFinestra")
      expect(response.body).not_to include("ErroreFuori")
    end
  end

  describe "i numeri in cima raccontano lo stesso periodo dell'elenco" do
    it "gli errori più vecchi del periodo non gonfiano i conteggi" do
      create(:error_group, project:, title: "Recente", last_seen_at: 2.hours.ago)
      create(:error_group, project:, title: "Vecchio", last_seen_at: 3.days.ago)

      get member_monitoring_error_groups_path

      expect(html.at_css('[data-test="stat-unresolved"]').text).to include("1")
    end
  end

  describe "elenco vuoto per il periodo" do
    it "dice che è il periodo, e offre di allargarlo invece di far credere che non sia mai arrivato niente" do
      create(:error_group, project:, title: "ErroreVecchissimo", last_seen_at: 40.days.ago)

      get member_monitoring_error_groups_path

      expect(html.at_css('[data-test="errors-no-match-range"]')).to be_present
      expect(html.at_css('[data-test="errors-empty"]')).to be_nil
      # CYRA-883: 40 days is past the 30-day button, so it widens back to that error's day.
      expect(html.at_css('[data-test="errors-widen-range"]')["href"]).to include("range=custom")
    end

    it "senza nemmeno un errore resta la spiegazione del primo giorno" do
      get member_monitoring_error_groups_path

      expect(html.at_css('[data-test="errors-empty"]')).to be_present
    end
  end
end
