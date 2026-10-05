# frozen_string_literal: true

require "rails_helper"

# CYRA-792 — il recupero degli avvisi uptime che non sono mai arrivati alla coda.
#
# Il cambio di stato è scritto (incident aperto o chiuso), l'avviso no: senza questo giro nessun
# controllo successivo lo ripropone, perché la transizione non si ripete su un incident già aperto.
RSpec.describe Uptime::ReconcileAlerts, type: :service do
  let(:monitor) { create(:uptime_monitor, current_status: :down) }

  # Argomenti attesi dell'avviso recuperato: il subject è l'incident, la rotta è quella del monitor.
  def alert(incident, event_type)
    hash_including(event_type: event_type, subject_type: "Uptime::Incident", subject_id: incident.id,
                   project_id: monitor.project_id, environment_id: monitor.environment_id)
  end

  describe "caduta mai annunciata" do
    it "consegna l'avviso una volta e segna l'incident come annunciato" do
      incident = create(:uptime_incident, :down_alert_pending, monitor:, started_at: 10.minutes.ago)

      expect { described_class.call }.to have_enqueued_job(Alerting::EvaluateJob)
        .with(alert(incident, "uptime_down"))
      expect(incident.reload.down_alerted_at).to be_present
    end

    it "un secondo giro non ri-annuncia lo stesso incident" do
      create(:uptime_incident, :down_alert_pending, monitor:, started_at: 10.minutes.ago)
      described_class.call

      expect { described_class.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "non tocca la caduta appena registrata: la consegna normale è ancora in corso" do
      create(:uptime_incident, :down_alert_pending, monitor:, started_at: 30.seconds.ago)

      expect { described_class.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "lascia stare le cadute più vecchie della finestra di recupero: un avviso di ieri è archeologia" do
      create(:uptime_incident, :down_alert_pending, monitor:, started_at: 2.days.ago)

      expect { described_class.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "non ripassa un incident già annunciato" do
      create(:uptime_incident, monitor:, started_at: 10.minutes.ago)

      expect { described_class.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end
  end

  describe "ripristino mai annunciato" do
    it "consegna l'avviso di rientro una volta e segna l'incident" do
      incident = create(:uptime_incident, :up_alert_pending, monitor:,
                        started_at: 30.minutes.ago, resolved_at: 10.minutes.ago)

      expect { described_class.call }.to have_enqueued_job(Alerting::EvaluateJob)
        .with(alert(incident, "uptime_up"))
      expect(incident.reload.up_alerted_at).to be_present
    end

    it "non tocca il ripristino appena registrato" do
      create(:uptime_incident, :up_alert_pending, monitor:,
             started_at: 30.minutes.ago, resolved_at: 30.seconds.ago)

      expect { described_class.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "un incident ancora aperto non ha nessun ripristino da annunciare" do
      incident = create(:uptime_incident, :up_alert_pending, monitor:, started_at: 30.minutes.ago,
                        resolved_at: nil)

      expect { described_class.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(alert(incident, "uptime_up"))
    end
  end

  # Revisione CYRA-792: il controllo che vede il sito tornare su manda subito «è tornato attivo». Se
  # il recupero mandasse dopo l'«è giù» rimasto indietro, l'ultimo avviso letto direbbe che il sito è
  # caduto mentre funziona — peggio del silenzio.
  describe "caduta rimasta indietro rispetto al rientro" do
    it "non annuncia la caduta se il rientro è già stato annunciato" do
      incident = create(:uptime_incident, :down_alert_pending, monitor:,
                        started_at: 30.minutes.ago, resolved_at: 10.minutes.ago,
                        up_alerted_at: 10.minutes.ago)

      expect { described_class.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
      expect(incident.reload.down_alerted_at).to be_nil
    end

    it "la caduta di un incident ancora aperto si annuncia normalmente" do
      incident = create(:uptime_incident, :down_alert_pending, monitor:,
                        started_at: 30.minutes.ago, resolved_at: nil)

      expect { described_class.call }.to have_enqueued_job(Alerting::EvaluateJob)
        .with(alert(incident, "uptime_down"))
    end
  end

  describe "due esecutori sulla stessa riga" do
    it "il secondo trova il segno e non accoda un doppione" do
      incident = create(:uptime_incident, :down_alert_pending, monitor:, started_at: 10.minutes.ago)
      described_class.call

      expect { Uptime::Incidents::Announce.call(incident: incident.reload, event_type: "uptime_down") }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
    end
  end

  describe "caduta e ripristino entrambi persi" do
    it "consegna prima la caduta e poi il rientro: la sequenza resta leggibile" do
      incident = create(:uptime_incident, :down_alert_pending, :up_alert_pending, monitor:,
                        started_at: 30.minutes.ago, resolved_at: 10.minutes.ago)

      described_class.call
      types = ActiveJob::Base.queue_adapter.enqueued_jobs
                             .map { |job| job[:args].first }
                             .select { |args| args["subject_id"] == incident.id }
                             .map { |args| args["event_type"] }
      expect(types).to eq(%w[uptime_down uptime_up])
    end
  end

  describe "esito" do
    it "restituisce quanti avvisi ha recuperato" do
      create(:uptime_incident, :down_alert_pending, monitor:, started_at: 10.minutes.ago)
      create(:uptime_incident, :up_alert_pending, monitor:,
             started_at: 40.minutes.ago, resolved_at: 20.minutes.ago)

      expect(described_class.call.value).to eq(2)
    end

    it "senza niente da recuperare non accoda nulla e conta zero" do
      expect { expect(described_class.call.value).to eq(0) }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end
  end

  describe "quando la coda è ancora guasta" do
    it "lascia l'incident pendente: il giro dopo riprova" do
      incident = create(:uptime_incident, :down_alert_pending, monitor:, started_at: 10.minutes.ago)
      allow(Alerting::EvaluateJob).to receive(:perform_later).and_raise(StandardError, "coda giù")

      expect { described_class.call }.not_to raise_error
      expect(incident.reload.down_alerted_at).to be_nil
    end

    it "una riga che esplode non ferma le altre del lotto" do
      rotta = create(:uptime_incident, :down_alert_pending, monitor:, started_at: 20.minutes.ago)
      buona = create(:uptime_incident, :down_alert_pending, monitor: create(:uptime_monitor),
                     started_at: 10.minutes.ago)
      allow(Alerting::EvaluateJob).to receive(:perform_later).and_call_original
      allow(Alerting::EvaluateJob).to receive(:perform_later)
        .with(hash_including(subject_id: rotta.id)).and_raise(StandardError, "coda giù")

      described_class.call
      expect(buona.reload.down_alerted_at).to be_present
    end
  end

  describe "lotto" do
    it "non accoda più di BATCH avvisi per giro" do
      stub_const("#{described_class}::BATCH", 1)
      create(:uptime_incident, :down_alert_pending, monitor:, started_at: 20.minutes.ago)
      create(:uptime_incident, :down_alert_pending, monitor: create(:uptime_monitor), started_at: 10.minutes.ago)

      expect { described_class.call }.to have_enqueued_job(Alerting::EvaluateJob).exactly(:once)
    end
  end
end
