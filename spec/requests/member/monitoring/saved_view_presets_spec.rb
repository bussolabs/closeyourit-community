# frozen_string_literal: true

require "rails_helper"

# CYRA-355 — la funzione che serve a non perdersi fra duemila gruppi e 55k righe si apriva dicendo
# «nessuna vista salvata» e chiedendo un nome: dava per scontato che chi arriva sappia già quali sono
# le domande giuste. Le viste pronte sono anche la documentazione di cosa si può comporre.
RSpec.describe "Member — viste già pronte su prestazioni e log", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }

  before { create(:membership, account: owner, organization:, role: :owner) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  def body = Nokogiri::HTML(response.body)

  # Il collegamento della vista già pronta, esattamente come lo preme chi usa il prodotto: si legge
  # dal pannello e lo si segue. Verificare i filtri "a mano" direbbe che l'elenco sa ordinare, non
  # che quella voce di menu porti dove promette — che è il difetto di CYRA-561.
  def open_preset(chiave)
    link = body.at_css(%([data-test="saved-view-preset-#{chiave}"]))
    expect(link).to be_present, "vista già pronta «#{chiave}» assente dal pannello"
    get link["href"]
  end

  # I titoli delle righe, nell'ordine in cui la pagina li mostra.
  def righe = body.css('[data-test="metric-group-row"] [data-test^="metric-group-link-"]').map(&:text)

  describe "prestazioni" do
    it "senza viste proprie ne propone tre già pronte" do
      sign_in(owner)
      create(:metric_group, project:)

      get member_monitoring_metric_groups_path

      %w[recent costliest untriaged].each do |chiave|
        expect(response.body).to include(I18n.t("shared.saved_views.preset_metrics_#{chiave}"))
      end
    end

    it "aprendone una, il filtro corrispondente è davvero attivo" do
      sign_in(owner)
      recente = create(:metric_group, project:, last_seen_at: 1.hour.ago, title: "SELECT recente")
      vecchio = create(:metric_group, project:, last_seen_at: 40.days.ago, title: "SELECT vecchio")

      # CYRA-340: il periodo non è più un filtro solo di questa pagina («seen») ma quello condiviso
      # con errori e log.
      get member_monitoring_metric_groups_path(range: "24h")

      expect(response.body).to include(recente.title)
      expect(response.body).not_to include(vecchio.title)
    end

    # CYRA-561 — la scorciatoia esiste per chi non sa da dove cominciare davanti a duecento voci, e
    # lo portava sul caso più insignificante: chiedeva l'ordine crescente (chiave senza trattino), e
    # in cima finiva la query eseguita una volta sola da un decimo di secondo.
    it "«quelli che costano di più» apre sull'operazione col tempo totale maggiore" do
      sign_in(owner)
      create(:metric_group, project:, title: "SELECT briciola", duration_total_ms: 103.0, samples_count: 1)
      create(:metric_group, project:, title: "SELECT macigno", duration_total_ms: 420_000.0, samples_count: 3_000)

      get member_monitoring_metric_groups_path
      open_preset("costliest")

      expect(righe.first).to eq("SELECT macigno")
    end

    # E deve essere la STESSA che si ottiene ordinando a mano per tempo totale: il difetto stava solo
    # nella scorciatoia, l'intestazione di colonna funzionava già.
    it "«quelli che costano di più» dà lo stesso ordine dell'intestazione «tempo totale»" do
      sign_in(owner)
      create(:metric_group, project:, title: "SELECT briciola", duration_total_ms: 103.0, samples_count: 1)
      create(:metric_group, project:, title: "SELECT medio", duration_total_ms: 9_000.0, samples_count: 40)
      create(:metric_group, project:, title: "SELECT macigno", duration_total_ms: 420_000.0, samples_count: 3_000)

      get member_monitoring_metric_groups_path(sort: "-total_duration")
      a_mano = righe

      # CYRA-694 — l'ordinamento appena usato viene ricordato: la visita nuda è rimandata
      # all'indirizzo che lo dichiara, e il pannello sta sulla pagina che ne esce.
      get member_monitoring_metric_groups_path
      follow_redirect! if response.redirect?
      open_preset("costliest")

      expect(righe).to eq(a_mano)
    end

    # CYRA-561 — chiedeva il periodo predefinito: premerla lasciava la pagina identica a com'era, e
    # una scorciatoia che non sposta niente sembra rotta. Ora risponde davvero a «cosa si è mosso di
    # recente», che è la domanda per cui era stata pensata.
    it "«visti più di recente» mette in cima l'ultima operazione vista, non la più costosa" do
      sign_in(owner)
      create(:metric_group, project:, title: "SELECT macigno",
                            duration_total_ms: 420_000.0, samples_count: 3_000, last_seen_at: 5.hours.ago)
      create(:metric_group, project:, title: "SELECT appena vista",
                            duration_total_ms: 12.0, samples_count: 1, last_seen_at: 1.minute.ago)

      get member_monitoring_metric_groups_path
      predefinito = righe

      open_preset("recent")

      expect(predefinito.first).to eq("SELECT macigno")
      expect(righe.first).to eq("SELECT appena vista")
    end

    it "«senza ticket» lascia fuori quelli già promossi" do
      sign_in(owner)
      aperto = create(:metric_group, project:, title: "SELECT aperto")
      promosso = create(:metric_group, project:, title: "SELECT promosso",
                                       ticket: create(:ticket, organization:, project:))

      get member_monitoring_metric_groups_path(open: "1", status: [ "unresolved" ])

      expect(response.body).to include(aperto.title)
      expect(response.body).not_to include(promosso.title)
    end

    # Whitelist: un periodo inventato ricade sul predefinito invece di far esplodere la pagina
    # (CYRA-340: prima non filtrava affatto, ora il predefinito è dichiarato dal selettore).
    it "un periodo inventato ricade sul predefinito e non rompe" do
      sign_in(owner)
      gruppo = create(:metric_group, project:, last_seen_at: 1.hour.ago, title: "SELECT recente")

      get member_monitoring_metric_groups_path(range: "sempre")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(gruppo.title)
      expect(body.at_css('[data-test="filter-chip-range"]')["hidden"]).not_to be_nil
    end

    it "chi ha già le sue viste non riceve suggerimenti" do
      sign_in(owner)
      create(:saved_view, account: owner, organization:, resource_type: "metric_groups", name: "La mia")

      get member_monitoring_metric_groups_path

      expect(response.body).not_to include(I18n.t("shared.saved_views.preset_metrics_recent"))
    end
  end

  describe "log" do
    it "senza viste proprie propone errori recenti e i più gravi" do
      sign_in(owner)
      create(:log_entry, project:)

      get member_monitoring_log_entries_path

      expect(response.body).to include(I18n.t("shared.saved_views.preset_logs_recent_errors"))
      expect(response.body).to include(I18n.t("shared.saved_views.preset_logs_fatal"))
    end

    # Una vista che non può che dare zero risultati sembra rotta: senza versioni non si offre.
    it "la vista dell'ultima versione compare solo se una versione c'è" do
      sign_in(owner)
      create(:log_entry, project:, release: nil)

      get member_monitoring_log_entries_path

      expect(response.body).not_to include("preset-latest_release")
    end

    it "con una versione pubblicata la offre, e filtra davvero" do
      sign_in(owner)
      allow_n_plus_one do
        create(:log_entry, project:, release: "v2.0", message: "Della versione nuova", occurred_at: 1.hour.ago)
        create(:log_entry, project:, release: "v1.0", message: "Della versione vecchia", occurred_at: 2.hours.ago)
      end

      get member_monitoring_log_entries_path

      expect(response.body).to include(I18n.t("shared.saved_views.preset_logs_latest_release", release: "v2.0"))

      get member_monitoring_log_entries_path(release: [ "v2.0" ])

      expect(response.body).to include("Della versione nuova")
      expect(response.body).not_to include("Della versione vecchia")
    end
  end
end
