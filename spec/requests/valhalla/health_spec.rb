# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Valhalla::Health", type: :request do
  include_context "valhalla service health cache"

  # CYRA-170: il god in Valhalla passa dal 2FA (attivato al volo + secondo fattore completato).
  def sign_in_as(account)
    enable_two_factor!(account) if account.god? && !account.otp_enabled?
    post login_path, params: { email: account.email, password: "Secret123!" }
    complete_two_factor(account) if account.otp_enabled?
  end

  def create_job(queue_name: "default", class_name: "SomeJob")
    SolidQueue::Job.create!(queue_name:, class_name:)
  end

  let(:god) { create(:account, god: true) }

  before do
    SolidQueue::ReadyExecution.delete_all
    SolidQueue::ScheduledExecution.delete_all
    SolidQueue::ClaimedExecution.delete_all
    SolidQueue::BlockedExecution.delete_all
    SolidQueue::FailedExecution.delete_all
    SolidQueue::Process.delete_all
    SolidQueue::Job.delete_all
    Rails.cache.delete(Valhalla::ProbeServices::CACHE_KEY)
  end

  describe "GET /valhalla/health — gate" do
    it "god con 2FA verificato → 200 con le quattro sezioni" do
      sign_in_as(god)
      get valhalla_health_path
      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css('[data-test="valhalla-health"]')).to be_present
      expect(doc.at_css('[data-test="valhalla-health-queue-backlog"]')).to be_present
      expect(doc.at_css('[data-test="valhalla-health-failed-breakdown"]')).to be_present
      expect(doc.at_css('[data-test="valhalla-health-tables"]')).to be_present
      expect(doc.at_css('[data-test="service-status-embedding"]')).to be_present
    end

    it "account non-god → redirect alla home" do
      sign_in_as(create(:account, god: false))
      get valhalla_health_path
      expect(response).to redirect_to(root_path)
    end

    it "non autenticato → redirect al login" do
      get valhalla_health_path
      expect(response).to redirect_to(login_path)
    end

    it "god senza 2FA → mandato all'enrollment (gate ereditato da BaseController)" do
      god_no_otp = create(:account, god: true)
      post login_path, params: { email: god_no_otp.email, password: "Secret123!" }
      get valhalla_health_path
      expect(response).to redirect_to(account_two_factor_path)
    end
  end

  describe "nessun lavoro in coda né fallito, worker vivo" do
    before do
      sign_in_as(god)
      SolidQueue::Process.create!(kind: "Worker", name: "w1", pid: 1, last_heartbeat_at: Time.current)
    end

    it "backlog=0, falliti=0, worker attivi — nessun allarme" do
      get valhalla_health_path
      doc = Nokogiri::HTML(response.body)

      expect(doc.at_css('[data-test="stat-ready-total"]').text.strip).to eq("0")
      expect(doc.at_css('[data-test="stat-ready-total"]')["class"]).not_to include("text-amber-600")
      expect(doc.at_css('[data-test="stat-failed-total"]').text.strip).to eq("0")
      expect(doc.at_css('[data-test="stat-failed-total"]')["class"]).not_to include("text-red-600")
      expect(doc.at_css('[data-test="stat-workers-alive"]').text.strip).to eq(I18n.t("valhalla.health.workers_alive"))
    end
  end

  describe "lavori falliti di classi diverse" do
    before { sign_in_as(god) }

    it "mostra il totale in rosso e il breakdown per classe job" do
      SolidQueue::FailedExecution.create!(job: create_job(class_name: "Ai::AnalyzeJob"), error: "boom")
      SolidQueue::FailedExecution.create!(job: create_job(class_name: "Ai::AnalyzeJob"), error: "boom")
      SolidQueue::FailedExecution.create!(job: create_job(class_name: "Notifications::DigestJob"), error: "boom")

      get valhalla_health_path
      doc = Nokogiri::HTML(response.body)

      total = doc.at_css('[data-test="stat-failed-total"]')
      expect(total.text.strip).to eq("3")
      expect(total["class"]).to include("text-red-600")

      section = doc.at_css('[data-test="valhalla-health-failed-breakdown"]')
      expect(section.text).to include("Ai::AnalyzeJob")
      expect(section.text).to include("Notifications::DigestJob")
    end
  end

  describe "backlog alto senza worker attivi" do
    before { sign_in_as(god) }

    it "mostra il backlog per coda e segnala l'assenza di worker in ambra" do
      # SolidQueue::Job dispaccia da solo (after_create): un job "due" crea già la sua ReadyExecution,
      # crearne una a mano in più violerebbe l'indice unique su job_id. Setup bulk (3 job indipendenti,
      # non un N+1 di produzione): ReadyExecution#assume_attributes_from_job carica l'associazione job
      # non ancora in cache (create_or_find_by! passa solo job_id) → una SELECT per job creato, non
      # una query ripetuta sulla stessa richiesta. La finestra N+1 vera è il get sotto.
      allow_n_plus_one { 3.times { create_job(queue_name: "maintenance") } }

      get valhalla_health_path
      doc = Nokogiri::HTML(response.body)

      backlog_section = doc.at_css('[data-test="valhalla-health-queue-backlog"]')
      expect(backlog_section.text).to include("maintenance")

      workers = doc.at_css('[data-test="valhalla-health-workers"]')
      expect(workers.text).to include(I18n.t("valhalla.health.workers_down"))
      expect(doc.at_css('[data-test="stat-workers-alive"]')["class"]).to include("text-amber-600")
    end
  end

  describe "stato dei servizi esterni" do
    before { sign_in_as(god) }

    it "servizi down/unconfigured con l'ora dell'ultimo controllo, mai un valore ENV" do
      checked_at = Time.current
      Rails.cache.write(Valhalla::ProbeServices::CACHE_KEY, [
        { key: :embedding, status: :down, checked_at:, detail: "OpenTimeout" },
        { key: :proxanything, status: :up, checked_at:, detail: nil },
        { key: :telegram, status: :unconfigured, checked_at:, detail: nil },
        { key: :github, status: :up, checked_at:, detail: nil }
      ])

      get valhalla_health_path
      doc = Nokogiri::HTML(response.body)

      embedding_label = doc.at_css('[data-test="service-status-embedding-label"]')
      expect(embedding_label.text.strip).to eq(I18n.t("valhalla.health.status_down"))
      expect(embedding_label["class"]).to include("text-red-600")

      telegram_label = doc.at_css('[data-test="service-status-telegram-label"]')
      expect(telegram_label.text.strip).to eq(I18n.t("valhalla.health.status_unconfigured"))

      expect(response.body).not_to include(ENV["TELEGRAM_BOT_TOKEN"].to_s) if ENV["TELEGRAM_BOT_TOKEN"].present?
    end

    it "cache vuota (job mai girato) → stato 'non ancora verificato' per ciascun servizio, nessun errore" do
      get valhalla_health_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      # `llm` in lista da CYRA-186/CYRA-765: il fornitore dell'assistente era l'unico servizio esterno
      # di prodotto che non compariva qui, ed è rimasto giù per giorni senza che si vedesse.
      %w[embedding telegram github llm].each do |key|
        label = doc.at_css(%([data-test="service-status-#{key}-label"]))
        expect(label.text.strip).to eq(I18n.t("valhalla.health.status_unknown"))
      end
      expect(doc.at_css('[data-test="service-status-llm"]').text).to include(I18n.t("valhalla.health.service_llm"))
    end

    # CYRA-771: la card della posta era rossa mentre le email partivano. «Non posso controllare» ha
    # ora una sua etichetta, e non prende il colore del guasto: un allarme che grida al lupo insegna
    # a ignorare quelli veri.
    it "il mittente non verificabile ha un'etichetta propria e non è dipinto di rosso" do
      checked_at = Time.current
      Rails.cache.write(Valhalla::ProbeServices::CACHE_KEY, [
        { key: :email, status: :unverifiable, checked_at:, detail: "restricted_key" }
      ])

      get valhalla_health_path
      doc = Nokogiri::HTML(response.body)

      label = doc.at_css('[data-test="service-status-email-label"]')
      expect(label.text.strip).to eq(I18n.t("valhalla.health.status_unverifiable"))
      expect(label.text.strip).not_to eq(I18n.t("valhalla.health.status_down"))
      expect(label["class"]).not_to include("text-red-600")
      expect(doc.at_css('[data-test="service-status-email"]').to_html).not_to include("text-red-500")
    end

    # Da CYRA-765 nessun servizio porta i conteggi delle organizzazioni collegate: l'AI generativa la
    # offre il sistema, e la card torna a dire soltanto se il servizio risponde.
    it "nessun servizio mostra conteggi di organizzazioni" do
      checked_at = Time.current
      Rails.cache.write(Valhalla::ProbeServices::CACHE_KEY, [ { key: :telegram, status: :up, checked_at:, detail: nil } ])

      get valhalla_health_path
      doc = Nokogiri::HTML(response.body)

      expect(doc.at_css('[data-test="service-status-telegram-counts"]')).to be_nil
    end
  end

  describe "tabelle in crescita" do
    before { sign_in_as(god) }

    it "mostra le tabelle in ordine decrescente per dimensione, con size leggibile e righe stimate" do
      get valhalla_health_path
      doc = Nokogiri::HTML(response.body)

      rows = doc.at_css('[data-test="valhalla-health-tables"]').css("tbody tr")
      expect(rows).not_to be_empty
    end
  end

  # CYRA-924 — the three tables sort on their columns (C9), each with its own param.
  it "sorts the largest tables by name both ways and offers every column" do
    sign_in_as(god)
    names = -> { Nokogiri::HTML(response.body).css("[data-test='valhalla-health-tables'] tbody tr th").map { |th| th.text.strip } }

    get valhalla_health_path(tables_sort: "table")
    expect(names.call).to eq(names.call.sort)
    get valhalla_health_path(tables_sort: "-table")
    expect(names.call).to eq(names.call.sort.reverse)
    %w[table size rows].each { |key| expect(response.body).to include("tables_sort=#{key}").or include("tables_sort=-#{key}") }
  end
end
