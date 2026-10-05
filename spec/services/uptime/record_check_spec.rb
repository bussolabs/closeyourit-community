# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::RecordCheck, type: :service do
  let(:monitor) { create(:uptime_monitor, current_status: :unknown) }

  def result(up:, code: 200, ms: 120, error: nil)
    Uptime::Ping::Result.new(up:, status_code: code, response_time_ms: ms, error:)
  end

  it "esito up: crea il check, monitor up, last_checked aggiornato" do
    travel_to(Time.utc(2026, 6, 26, 12)) do
      expect { described_class.call(monitor:, result: result(up: true)) }.to change(monitor.checks, :count).by(1)
      expect(monitor.reload).to be_status_up
      expect(monitor.last_checked_at).to be_within(1).of(Time.utc(2026, 6, 26, 12))
    end
  end

  # La caduta si apre alla CONFERMA: due controlli falliti di fila col default (CYRA-776).
  it "down confermato dopo up: apre un incident e mette down" do
    monitor.status_up!
    described_class.call(monitor:, result: result(up: false, code: 500, error: "x"))
    expect { described_class.call(monitor:, result: result(up: false, code: 500, error: "x")) }
      .to change(monitor.incidents.open, :count).by(1)
    expect(monitor.reload).to be_status_down
  end

  it "recovery (up dopo down): chiude l'incident aperto" do
    monitor.status_down!
    incident = create(:uptime_incident, monitor:, resolved_at: nil)
    described_class.call(monitor:, result: result(up: true))
    expect(incident.reload).to be_resolved
    expect(monitor.reload).to be_status_up
  end

  it "down mentre già down: NON apre un secondo incident" do
    monitor.status_down!
    create(:uptime_incident, monitor:, resolved_at: nil)
    expect { described_class.call(monitor:, result: result(up: false, error: "x")) }
      .not_to change(Uptime::Incident, :count)
  end

  it "up mentre già up: nessun incident" do
    monitor.status_up!
    expect { described_class.call(monitor:, result: result(up: true)) }
      .not_to change(Uptime::Incident, :count)
  end

  # CYRA-271: il replace della riga monitor (HTML: nome/URL/stato) va sullo stream per-progetto.
  describe "isolamento del replace realtime (CYRA-271)" do
    let(:target) { ActionView::RecordIdentifier.dom_id(monitor) }

    it "manda il replace della riga monitor sullo stream per-progetto" do
      monitor.status_up!
      expect { described_class.call(monitor:, result: result(up: false, error: "x")) }
        .to have_broadcasted_to(Realtime::Streams.project_uptime(monitor.project)).with(a_string_including(target))
    end

    it "NON fa viaggiare l'HTML della riga sullo stream org-wide" do
      monitor.status_up!
      expect { described_class.call(monitor:, result: result(up: false, error: "x")) }
        .not_to have_broadcasted_to(Realtime::Streams.uptime(monitor.project.organization)).with(a_string_including(target))
    end
  end

  describe "serializzazione dei check concorrenti (CYRA-269)" do
    it "prende un lock sul monitor prima del check-then-act su open_incident" do
      expect(monitor).to receive(:lock!).and_call_original
      described_class.call(monitor:, result: result(up: false, error: "x"))
    end

    it "al recovery chiude TUTTI gli incident aperti, non solo il primo (auto-ripara i doppioni pre-lock)" do
      monitor.status_down!
      create(:uptime_incident, monitor:, resolved_at: nil, started_at: 2.hours.ago)
      create(:uptime_incident, monitor:, resolved_at: nil, started_at: 1.hour.ago) # doppione residuo

      expect { described_class.call(monitor:, result: result(up: true)) }
        .to change { monitor.incidents.open.count }.from(2).to(0)
    end
  end

  # CYRA-776 — l'incident si apriva al PRIMO controllo andato storto: partiva l'avviso, al giro dopo
  # il sito rispondeva, l'incident si chiudeva e partiva anche il rientro. Due notifiche per un
  # inciampo di rete (15 aperture e 14 chiusure entro sessanta secondi in quattro giorni, nessun
  # disservizio reale). Ora l'apertura pretende una conferma: `failure_threshold` controlli falliti
  # DI FILA. La chiusura resta al primo successo — un guasto vero si annuncia con un minuto di
  # ritardo, un inciampo non si annuncia affatto.
  describe "conferma prima di dichiarare il sito irraggiungibile (CYRA-776)" do
    include ActiveJob::TestHelper

    def ping_down = described_class.call(monitor:, result: result(up: false, code: 500, error: "x"))
    def ping_up = described_class.call(monitor:, result: result(up: true))

    it "un solo controllo fallito non apre nessun incident e non muove lo stato (Scenario 1)" do
      monitor.status_up!
      expect { ping_down }.not_to change(Uptime::Incident, :count)
      expect(monitor.reload).to be_status_up
      expect(monitor.consecutive_failures).to eq(1)
    end

    it "un solo controllo fallito non manda l'avviso di irraggiungibilità (Scenario 1)" do
      monitor.status_up!
      expect { ping_down }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "fallito poi riuscito: nessun incident, nessuna notifica, contatore azzerato (Scenario 1)" do
      monitor.status_up!
      ping_down
      expect { ping_up }.not_to have_enqueued_job(Alerting::EvaluateJob)
      expect(monitor.reload.consecutive_failures).to eq(0)
      expect(monitor).to be_status_up
      expect(Uptime::Incident.count).to eq(0)
    end

    it "due controlli falliti di fila aprono l'incident e mettono il monitor giù" do
      monitor.status_up!
      ping_down
      expect { ping_down }.to change { monitor.incidents.open.count }.from(0).to(1)
      expect(monitor.reload).to be_status_down
    end

    it "l'avviso di irraggiungibilità parte alla conferma, una volta sola" do
      monitor.status_up!
      ping_down
      expect { ping_down }.to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "uptime_down", subject_type: "Uptime::Incident")).once
    end

    it "un successo in mezzo azzera la conferma: fallito, riuscito, fallito non apre niente" do
      monitor.status_up!
      ping_down
      ping_up
      expect { ping_down }.not_to change(Uptime::Incident, :count)
      expect(monitor.reload).to be_status_up
    end

    it "la soglia è per monitor: con 1 l'incident si apre al primo fallito" do
      monitor.update!(failure_threshold: 1)
      monitor.status_up!
      expect { ping_down }.to change { monitor.incidents.open.count }.from(0).to(1)
      expect(monitor.reload).to be_status_down
    end

    it "con soglia 3 l'incident si apre al terzo fallito, non prima" do
      monitor.update!(failure_threshold: 3)
      monitor.status_up!
      expect { 2.times { ping_down } }.not_to change(Uptime::Incident, :count)
      expect { ping_down }.to change { monitor.incidents.open.count }.from(0).to(1)
    end

    it "il monitor mai controllato resta unknown finché la caduta non è confermata" do
      expect { ping_down }.not_to change(Uptime::Incident, :count)
      expect(monitor.reload).to be_status_unknown
    end

    it "la chiusura resta al primo successo e azzera il contatore" do
      monitor.status_up!
      2.times { ping_down }
      expect { ping_up }.to change { monitor.incidents.open.count }.from(1).to(0)
      expect(monitor.reload.consecutive_failures).to eq(0)
      expect(monitor).to be_status_up
    end

    it "con l'incident già aperto un altro fallito non ne apre un secondo (il contatore sale)" do
      monitor.status_up!
      3.times { ping_down }
      expect(monitor.reload.consecutive_failures).to eq(3)
      expect(monitor.incidents.count).to eq(1)
      expect(monitor).to be_status_down
    end

    # La disponibilità (% uptime, barre della status page) si calcola sui ping, non sugli incident:
    # un fallito non confermato NON sparisce dai numeri, cambia solo che non viene dichiarato guasto.
    it "il controllo fallito resta scritto: la disponibilità continua a contarlo" do
      monitor.status_up!
      expect { ping_down }.to change { monitor.checks.where(up: false).count }.by(1)
      expect(Uptime::Monitor.uptime_percents([ monitor.id ], 1.hour.ago)[monitor.id]).to eq(0.0)
    end
  end

  describe "trigger alerting" do
    include ActiveJob::TestHelper

    it "down confermato dopo up: accoda EvaluateJob uptime_down per l'incident" do
      monitor.status_up!
      described_class.call(monitor:, result: result(up: false, error: "x")) # conferma pendente (CYRA-776)
      expect { described_class.call(monitor:, result: result(up: false, error: "x")) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "uptime_down", subject_type: "Uptime::Incident",
                             project_id: monitor.project_id, environment_id: monitor.environment_id))
    end

    it "recovery (up dopo down): accoda EvaluateJob uptime_up" do
      monitor.status_down!
      create(:uptime_incident, monitor:, resolved_at: nil)
      expect { described_class.call(monitor:, result: result(up: true)) }
        .to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "uptime_up"))
    end

    it "nessuna transizione (up mentre già up): NON accoda alcun job" do
      monitor.status_up!
      expect { described_class.call(monitor:, result: result(up: true)) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "down mentre già down: NON accoda (nessuna transizione)" do
      monitor.status_down!
      create(:uptime_incident, monitor:, resolved_at: nil)
      expect { described_class.call(monitor:, result: result(up: false, error: "x")) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
    end
  end

  describe "scadenza certificato" do
    def ssl_result(expires_at)
      Uptime::Ping::Result.new(up: true, status_code: 200, response_time_ms: 10, error: nil,
                               ssl_expires_at: expires_at)
    end

    it "aggiorna ssl_expires_at sul monitor a ogni ping che lo osserva" do
      expires = 60.days.from_now
      described_class.call(monitor:, result: ssl_result(expires))
      expect(monitor.reload.ssl_expires_at).to be_within(1).of(expires)
    end

    it "senza warn_days configurato non avvisa mai" do
      monitor.update!(ssl_expiry_warn_days: nil)
      expect do
        described_class.call(monitor:, result: ssl_result(1.day.from_now))
      end.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    context "con warn_days = 14" do
      before { monitor.update!(ssl_expiry_warn_days: 14) }

      it "certificato oltre la finestra (14 giorni + 1s) → nessun avviso" do
        travel_to Time.utc(2026, 7, 2, 12) do
          expect do
            described_class.call(monitor:, result: ssl_result(14.days.from_now + 1.second))
          end.not_to have_enqueued_job(Alerting::EvaluateJob)
        end
      end

      it "certificato dentro la finestra (14 giorni - 1s) → avviso uptime_ssl_expiring" do
        travel_to Time.utc(2026, 7, 2, 12) do
          expect do
            described_class.call(monitor:, result: ssl_result(14.days.from_now - 1.second))
          end.to have_enqueued_job(Alerting::EvaluateJob)
            .with(hash_including(event_type: "uptime_ssl_expiring", subject_type: "Uptime::Monitor",
                                 subject_id: monitor.id))
          expect(monitor.reload.ssl_alerted_on).to eq(Date.new(2026, 7, 2))
        end
      end

      it "dedup giornaliero: secondo check nello stesso giorno non ri-avvisa" do
        travel_to Time.utc(2026, 7, 2, 12) do
          described_class.call(monitor:, result: ssl_result(3.days.from_now))
          expect do
            described_class.call(monitor:, result: ssl_result(3.days.from_now))
          end.not_to have_enqueued_job(Alerting::EvaluateJob)
        end
      end

      it "il giorno dopo ri-avvisa (ssl_alerted_on scaduto)" do
        travel_to Time.utc(2026, 7, 2, 12) do
          described_class.call(monitor:, result: ssl_result(3.days.from_now))
        end
        travel_to Time.utc(2026, 7, 3, 12) do
          expect do
            described_class.call(monitor:, result: ssl_result(2.days.from_now))
          end.to have_enqueued_job(Alerting::EvaluateJob)
              .with(hash_including(event_type: "uptime_ssl_expiring"))
          end
      end

      it "ping senza certificato (http) non tocca ssl_expires_at e non avvisa" do
        monitor.update!(ssl_expires_at: 90.days.from_now)
        expect do
          described_class.call(monitor:, result: Uptime::Ping::Result.new(
            up: true, status_code: 200, response_time_ms: 10, error: nil
          ))
        end.not_to have_enqueued_job(Alerting::EvaluateJob)
        expect(monitor.reload.ssl_expires_at).to be_present
      end
    end
  end

  # CYRA-151: il sito risponde ma è lento oltre la soglia configurata → avviso uptime_slow. Solo su
  # check up (un down ha già uptime_down), subject = il monitor, dedup giornaliero come lo SSL.
  describe "avviso di lentezza (uptime_slow)" do
    include ActiveJob::TestHelper

    it "up oltre la soglia → accoda EvaluateJob uptime_slow (subject = monitor)" do
      monitor.update!(latency_threshold_ms: 500)
      monitor.status_up!
      expect { described_class.call(monitor:, result: result(up: true, ms: 800)) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "uptime_slow", subject_type: "Uptime::Monitor", subject_id: monitor.id,
                             project_id: monitor.project_id, environment_id: monitor.environment_id))
    end

    it "up entro la soglia → nessun avviso" do
      monitor.update!(latency_threshold_ms: 500)
      monitor.status_up!
      expect { described_class.call(monitor:, result: result(up: true, ms: 200)) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "soglia non impostata (nil) → nessun avviso anche se lentissimo" do
      monitor.status_up!
      expect { described_class.call(monitor:, result: result(up: true, ms: 5_000)) }
        .not_to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "uptime_slow"))
    end

    it "check down → nessun avviso di lentezza (ha già uptime_down)" do
      monitor.update!(latency_threshold_ms: 100)
      monitor.status_up!
      expect { described_class.call(monitor:, result: result(up: false, ms: nil, error: "x")) }
        .not_to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "uptime_slow"))
    end

    it "dedup giornaliero: il secondo check lento nello stesso giorno non ri-avvisa" do
      monitor.update!(latency_threshold_ms: 500)
      monitor.status_up!
      travel_to Time.utc(2026, 7, 2, 12) do
        described_class.call(monitor:, result: result(up: true, ms: 900))
        expect { described_class.call(monitor:, result: result(up: true, ms: 900)) }
          .not_to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "uptime_slow"))
        expect(monitor.reload.latency_alerted_on).to eq(Date.new(2026, 7, 2))
      end
    end

    it "il giorno dopo ri-avvisa (latency_alerted_on scaduto)" do
      monitor.update!(latency_threshold_ms: 500)
      monitor.status_up!
      travel_to(Time.utc(2026, 7, 2, 12)) { described_class.call(monitor:, result: result(up: true, ms: 900)) }
      travel_to Time.utc(2026, 7, 3, 12) do
        expect { described_class.call(monitor:, result: result(up: true, ms: 900)) }
          .to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "uptime_slow"))
      end
    end
  end

  # Regressione: il monitor viene SALVATO a ogni ping, quindi qualunque validazione ancora viva
  # sull'update fa fallire l'intera transazione — e il check non viene scritto. È successo davvero
  # con project_supports_uptime, per nove giorni, un fallimento al minuto.
  describe "il progetto perde la piattaforma web/server dopo la creazione del monitor" do
    it "continua a registrare il check invece di far esplodere il job" do
      monitor.project.platforms.destroy_all

      expect { described_class.call(monitor:, result: result(up: true)) }
        .to change(monitor.checks, :count).by(1)
      expect(monitor.reload).to be_status_up
    end
  end

  # CYRA-792 — l'avviso non si perde se la coda non lo accetta.
  #
  # Il cambio di stato veniva committato PRIMA dell'accodamento e la transizione viveva solo in
  # memoria: un accodamento fallito lì lasciava l'incident aperto senza avviso, e nessun controllo
  # successivo lo riproponeva. Ora l'intento di avviso sta scritto sull'incident (`down_alerted_at` /
  # `up_alerted_at` nil = da consegnare) e il segno si scrive DOPO l'accodamento riuscito.
  describe "intento di avviso scritto insieme al cambio di stato (CYRA-792)" do
    def ping_down = described_class.call(monitor:, result: result(up: false, code: 500, error: "x"))
    def ping_up = described_class.call(monitor:, result: result(up: true))

    it "l'avviso consegnato alla coda si segna sull'incident" do
      monitor.status_up!
      ping_down
      ping_down
      expect(monitor.incidents.open.sole.down_alerted_at).to be_present
    end

    it "il ripristino consegnato si segna sull'incident" do
      monitor.status_down!
      incident = create(:uptime_incident, monitor:, resolved_at: nil)
      ping_up
      expect(incident.reload.up_alerted_at).to be_present
    end

    context "quando l'accodamento dell'avviso fallisce" do
      before { allow(Alerting::EvaluateJob).to receive(:perform_later).and_raise(StandardError, "coda giù") }

      it "la caduta resta registrata e l'avviso resta da consegnare" do
        monitor.status_up!
        ping_down
        expect { ping_down }.to raise_error(StandardError, "coda giù")

        incident = monitor.incidents.open.sole
        expect(incident.down_alerted_at).to be_nil
        expect(monitor.reload).to be_status_down
      end

      it "il ripristino resta registrato e l'avviso resta da consegnare" do
        monitor.status_down!
        incident = create(:uptime_incident, monitor:, resolved_at: nil)
        expect { ping_up }.to raise_error(StandardError, "coda giù")

        expect(incident.reload).to be_resolved
        expect(incident.up_alerted_at).to be_nil
      end
    end

    it "il controllo successivo recupera la caduta rimasta senza avviso, una volta sola" do
      monitor.status_down!
      incident = create(:uptime_incident, :down_alert_pending, monitor:, resolved_at: nil)

      expect { ping_down }.to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "uptime_down", subject_id: incident.id))
      expect(incident.reload.down_alerted_at).to be_present
      expect { ping_down }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    # Revisione CYRA-792: se il sito torna su prima che la caduta sia stata recuperata, il rientro
    # parte subito e la caduta NON deve più partire — l'ultimo avviso letto direbbe «è giù» su un sito
    # che funziona.
    it "il rientro annunciato chiude la partita: la caduta rimasta indietro non parte più" do
      monitor.status_down!
      incident = create(:uptime_incident, :down_alert_pending, monitor:, resolved_at: nil,
                        started_at: 30.minutes.ago)

      ping_up
      expect(incident.reload.up_alerted_at).to be_present
      expect(incident.down_alerted_at).to be_nil

      travel_to(3.minutes.from_now) do
        expect { Uptime::ReconcileAlerts.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
      end
    end

    it "con l'avviso già consegnato un altro controllo fallito non ri-avvisa" do
      monitor.status_down!
      create(:uptime_incident, monitor:, resolved_at: nil)

      expect { ping_down }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "al recovery i doppioni residui si chiudono già annunciati: il rientro si avvisa una volta" do
      monitor.status_down!
      vecchio = create(:uptime_incident, monitor:, resolved_at: nil, started_at: 2.hours.ago)
      doppione = create(:uptime_incident, monitor:, resolved_at: nil, started_at: 1.hour.ago)

      expect { ping_up }.to have_enqueued_job(Alerting::EvaluateJob).exactly(:once)
      expect(vecchio.reload.up_alerted_at).to be_present
      expect(doppione.reload.up_alerted_at).to be_present
    end

    # La soppressione giornaliera (SSL e lentezza) veniva scritta PRIMA dell'accodamento: un
    # accodamento fallito zittiva il promemoria per tutto il resto del giorno.
    context "promemoria a cadenza giornaliera" do
      before { allow(Alerting::EvaluateJob).to receive(:perform_later).and_raise(StandardError, "coda giù") }

      it "il certificato in scadenza non resta zittito per la giornata" do
        monitor.update!(ssl_expiry_warn_days: 14)
        expect do
          described_class.call(monitor:, result: Uptime::Ping::Result.new(
            up: true, status_code: 200, response_time_ms: 10, error: nil, ssl_expires_at: 3.days.from_now
          ))
        end.to raise_error(StandardError, "coda giù")

        expect(monitor.reload.ssl_alerted_on).to be_nil
      end

      it "la lentezza non resta zittita per la giornata" do
        monitor.update!(latency_threshold_ms: 500)
        monitor.status_up!
        expect { described_class.call(monitor:, result: result(up: true, ms: 900)) }
          .to raise_error(StandardError, "coda giù")

        expect(monitor.reload.latency_alerted_on).to be_nil
      end
    end

    it "il controllo successivo dello stesso giorno riprova il promemoria del certificato" do
      monitor.update!(ssl_expiry_warn_days: 14)
      scadenza = Uptime::Ping::Result.new(up: true, status_code: 200, response_time_ms: 10, error: nil,
                                          ssl_expires_at: 3.days.from_now)
      allow(Alerting::EvaluateJob).to receive(:perform_later).and_raise(StandardError, "coda giù")
      expect { described_class.call(monitor:, result: scadenza) }.to raise_error(StandardError)
      allow(Alerting::EvaluateJob).to receive(:perform_later).and_call_original

      expect { described_class.call(monitor:, result: scadenza) }.to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "uptime_ssl_expiring"))
      expect(monitor.reload.ssl_alerted_on).to eq(Date.current)
    end

    it "il controllo successivo dello stesso giorno riprova il promemoria di lentezza" do
      monitor.update!(latency_threshold_ms: 500)
      monitor.status_up!
      allow(Alerting::EvaluateJob).to receive(:perform_later).and_raise(StandardError, "coda giù")
      expect { described_class.call(monitor:, result: result(up: true, ms: 900)) }.to raise_error(StandardError)
      allow(Alerting::EvaluateJob).to receive(:perform_later).and_call_original

      expect { described_class.call(monitor:, result: result(up: true, ms: 900)) }
        .to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "uptime_slow"))
      expect(monitor.reload.latency_alerted_on).to eq(Date.current)
    end
  end
end
