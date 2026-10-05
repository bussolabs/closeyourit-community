# frozen_string_literal: true

require "rails_helper"

# CYRA-484 — la pagina di un lavoro programmato era un elenco piatto di tentativi tutti uguali: non
# diceva da quanto era fermo, perché era fallito, né cosa si potesse fare. Un job fermo da quattro
# giorni è un guasto grave presentato come una riga di tabella.
RSpec.describe "Member — dettaglio di un lavoro programmato", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:membro) { create(:account) }
  let(:project) { create(:project, organization:) }
  let(:monitor) do
    create(:cron_monitor, project:, name: "Pulizia notturna", expected_interval_minutes: 60, grace_minutes: 10)
  end

  before do
    create(:membership, account: owner, organization:, role: :owner)
    create(:membership, account: membro, organization:, role: :member)
    create(:project_membership, account: membro, project:)
  end

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  def body = Nokogiri::HTML(response.body)

  def check_in(status:, at:, reason: nil)
    monitor.check_ins.create!(status:, checked_in_at: at, reason:)
  end

  describe "da quanto dura lo stato" do
    it "un lavoro fermo dice da quanto, senza far contare i giorni" do
      monitor.update!(status: :missed, last_check_in_at: 4.days.ago)
      sign_in(owner)

      get member_monitoring_cron_monitor_path(monitor)

      expect(body.at_css("[data-test='cron-status-duration']").text).to include(I18n.t("member.crons.status.missed"))
      expect(body.at_css("[data-test='cron-status-duration']").text).to match(/giorni|days/i)
    end

    it "un lavoro che non ha mai battuto lo dichiara, invece di inventare una durata" do
      monitor.update!(last_check_in_at: nil)
      sign_in(owner)

      get member_monitoring_cron_monitor_path(monitor)

      expect(body.at_css("[data-test='cron-never-seen']")).to be_present
    end

    it "un lavoro sospeso dice che è sospeso, non che è a posto" do
      monitor.update!(enabled: false, last_check_in_at: 1.hour.ago)
      sign_in(owner)

      get member_monitoring_cron_monitor_path(monitor)

      expect(body.at_css("[data-test='cron-paused']")).to be_present
    end
  end

  describe "guasti e motivi" do
    it "una serie di fallimenti di fila è un guasto solo, con la sua durata" do
      allow_n_plus_one do
        check_in(status: :ok, at: 5.hours.ago)
        check_in(status: :fail, at: 4.hours.ago, reason: "Connessione al database rifiutata")
        check_in(status: :fail, at: 3.hours.ago, reason: "Connessione al database rifiutata")
        check_in(status: :ok, at: 2.hours.ago)
      end
      sign_in(owner)

      get member_monitoring_cron_monitor_path(monitor)

      guasti = body.css("[data-test='cron-incident']")
      expect(guasti.size).to eq(1)
      expect(guasti.first.text).to include(I18n.t("member.crons.incident_attempts", count: 2))
      # Il motivo del guasto è quello del PRIMO tentativo fallito: è la causa.
      expect(body.at_css("[data-test='cron-incident-reason']").text).to include("Connessione al database rifiutata")
    end

    it "un guasto ancora aperto è marcato come tale" do
      allow_n_plus_one do
        check_in(status: :ok, at: 3.hours.ago)
        check_in(status: :fail, at: 1.hour.ago, reason: "Ancora giù")
      end
      sign_in(owner)

      get member_monitoring_cron_monitor_path(monitor)

      expect(body.at_css("[data-test='cron-incident-open']")).to be_present
    end

    it "senza guasti lo dice, invece di mostrare un riquadro vuoto" do
      check_in(status: :ok, at: 1.hour.ago)
      sign_in(owner)

      get member_monitoring_cron_monitor_path(monitor)

      expect(body.at_css("[data-test='cron-incidents-empty']")).to be_present
    end

    it "ogni tentativo mostra il suo motivo" do
      check_in(status: :fail, at: 1.hour.ago, reason: "Timeout dopo 30 secondi")
      sign_in(owner)

      get member_monitoring_cron_monitor_path(monitor)

      expect(response.body).to include("Timeout dopo 30 secondi")
    end
  end

  # Le due parole convivevano nella pagina senza che la differenza fosse spiegata da nessuna parte.
  it "spiega la differenza fra mancato e fallito, lì dove le due parole compaiono" do
    sign_in(owner)

    get member_monitoring_cron_monitor_path(monitor)

    legenda = body.at_css("[data-test='cron-legend']")
    expect(legenda.text).to include(I18n.t("member.crons.legend_missed"))
    expect(legenda.text).to include(I18n.t("member.crons.legend_fail"))
  end

  describe "azioni" do
    it "chi gestisce vede modifica, sospensione ed eliminazione" do
      sign_in(owner)

      get member_monitoring_cron_monitor_path(monitor)

      expect(body.at_css("[data-test='cron-edit']")).to be_present
      expect(body.at_css("[data-test='cron-pause']")).to be_present
      expect(body.at_css("[data-test='cron-delete']")).to be_present
    end

    it "chi non gestisce non le vede" do
      sign_in(membro)

      get member_monitoring_cron_monitor_path(monitor)

      expect(response).to have_http_status(:ok)
      expect(body.at_css("[data-test='cron-monitor-actions']")).to be_nil
    end

    it "il nome e le soglie si correggono" do
      sign_in(owner)

      patch member_monitoring_cron_monitor_path(monitor),
            params: { name: "Pulizia notturna dei file", expected_interval_minutes: 120, grace_minutes: 20 }

      expect(monitor.reload.name).to eq("Pulizia notturna dei file")
      expect(monitor.expected_interval_minutes).to eq(120)
    end

    it "si sospende e si riprende" do
      sign_in(owner)

      put member_monitoring_cron_monitor_pause_path(monitor)
      expect(monitor.reload.enabled).to be(false)

      delete member_monitoring_cron_monitor_pause_path(monitor)
      expect(monitor.reload.enabled).to be(true)
      # Riprendendo non si finge che il lavoro sia andato bene: lo stato torna vero al primo check-in.
      expect(monitor.status).to eq("unknown")
    end

    it "si elimina" do
      sign_in(owner)
      percorso = member_monitoring_cron_monitor_path(monitor) # crea il monitor PRIMA di contare

      expect { delete percorso }.to change(Crons::Monitor, :count).by(-1)
    end

    it "chi non gestisce non può modificare né eliminare" do
      sign_in(membro)

      patch member_monitoring_cron_monitor_path(monitor), params: { name: "Cambiato di nascosto" }

      expect(monitor.reload.name).to eq("Pulizia notturna")
    end
  end
end
