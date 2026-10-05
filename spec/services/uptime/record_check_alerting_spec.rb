# frozen_string_literal: true

require "rails_helper"

# DoD CYRA-207: con le regole di alerting di default installate al provisioning, una caduta reale di un
# sito produce una notifica ricevuta dal destinatario (owner), e il ripristino la notifica di rientro.
# Percorso completo: Uptime::RecordCheck (transizione) → Alerting::EvaluateJob → Alerting::Notification.
RSpec.describe Uptime::RecordCheck, type: :service do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let!(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) }
  end
  let(:monitor) { create(:uptime_monitor, project: project) }

  def result(up:, code: 200, error: nil)
    Uptime::Ping::Result.new(up: up, status_code: code, response_time_ms: 120, error: error)
  end

  describe "notifica reale di caduta e ripristino (CYRA-207)" do
    before { Alerting::Rules::InstallDefaults.call(organization: organization) }

    it "una caduta del sito consegna una notifica in-app al destinatario" do
      monitor.status_up!
      # Una caduta vera si conferma: col default servono due controlli falliti di fila prima che
      # l'incident si apra e l'avviso parta (CYRA-776).
      perform_enqueued_jobs do
        2.times { described_class.call(monitor: monitor, result: result(up: false, code: 500, error: "500")) }
      end
      expect(Alerting::Notification.where(account: owner, via: :in_app)).to exist
    end

    it "il ripristino del sito consegna la notifica di rientro" do
      monitor.status_down!
      create(:uptime_incident, monitor: monitor, resolved_at: nil)
      perform_enqueued_jobs do
        described_class.call(monitor: monitor, result: result(up: true))
      end
      expect(Alerting::Notification.where(account: owner, via: :in_app)).to exist
    end
  end

  # CYRA-151: la lentezza oltre soglia arriva davvero fino alla notifica in-app (regola di default
  # uptime_slow installata al provisioning). Copre l'intero flusso: RecordCheck → EvaluateJob →
  # Alerting::Notification con event_type uptime_slow (che deve esistere nell'enum della notifica).
  describe "avviso di lentezza reale (CYRA-151)" do
    before { Alerting::Rules::InstallDefaults.call(organization: organization) }

    it "un check lento oltre la soglia consegna una notifica in-app uptime_slow al destinatario" do
      monitor.update!(latency_threshold_ms: 500)
      monitor.status_up!
      perform_enqueued_jobs do
        described_class.call(monitor: monitor, result: Uptime::Ping::Result.new(
          up: true, status_code: 200, response_time_ms: 900, error: nil
        ))
      end
      expect(Alerting::Notification.where(account: owner, via: :in_app, event_type: :uptime_slow)).to exist
    end
  end

  # CYRA-792 — Scenario 1: la coda non accetta l'avviso della caduta. Senza recupero l'avviso è perso
  # per sempre (l'incident resta aperto e nessun controllo ripete la transizione). Qui si prova il
  # percorso intero: avviso perso → giro di recupero → notifica ricevuta, UNA sola volta.
  describe "avviso perso dalla coda e poi recuperato (CYRA-792)" do
    before { Alerting::Rules::InstallDefaults.call(organization: organization) }

    def caduta_confermata_con_coda_guasta
      allow(Alerting::EvaluateJob).to receive(:perform_later).and_raise(StandardError, "coda giù")
      2.times do
        described_class.call(monitor: monitor, result: result(up: false, code: 500, error: "500"))
      rescue StandardError
        nil
      end
      allow(Alerting::EvaluateJob).to receive(:perform_later).and_call_original
    end

    it "senza recupero il destinatario non riceve niente, ma il disservizio resta scritto" do
      monitor.status_up!
      caduta_confermata_con_coda_guasta

      expect(Alerting::Notification.where(account: owner)).not_to exist
      expect(monitor.incidents.open.sole.down_alerted_at).to be_nil
    end

    it "il recupero consegna la notifica della caduta" do
      monitor.status_up!
      caduta_confermata_con_coda_guasta

      travel_to(3.minutes.from_now) { perform_enqueued_jobs { Uptime::ReconcileAlerts.call } }
      expect(Alerting::Notification.where(account: owner, via: :in_app, event_type: :uptime_down).count).to eq(1)
    end

    it "un secondo giro di recupero non consegna un secondo avviso" do
      monitor.status_up!
      caduta_confermata_con_coda_guasta

      travel_to(3.minutes.from_now) { perform_enqueued_jobs { Uptime::ReconcileAlerts.call } }
      travel_to(4.minutes.from_now) { perform_enqueued_jobs { Uptime::ReconcileAlerts.call } }
      expect(Alerting::Notification.where(account: owner, via: :in_app, event_type: :uptime_down).count).to eq(1)
    end

    it "anche il ripristino perso arriva al giro di recupero" do
      monitor.status_down!
      incident = create(:uptime_incident, monitor: monitor, resolved_at: nil, started_at: 30.minutes.ago)
      allow(Alerting::EvaluateJob).to receive(:perform_later).and_raise(StandardError, "coda giù")
      begin
        described_class.call(monitor: monitor, result: result(up: true))
      rescue StandardError
        nil
      end
      allow(Alerting::EvaluateJob).to receive(:perform_later).and_call_original

      expect(incident.reload).to be_resolved
      travel_to(3.minutes.from_now) { perform_enqueued_jobs { Uptime::ReconcileAlerts.call } }
      expect(Alerting::Notification.where(account: owner, via: :in_app, event_type: :uptime_up).count).to eq(1)
    end
  end
end
