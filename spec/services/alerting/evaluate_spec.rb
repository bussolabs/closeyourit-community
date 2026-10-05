# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Evaluate do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let!(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) }
  end
  let(:group) { create(:error_group, project: project, title: "RuntimeError: boom") }

  def evaluate_error(event_type: "error_new", level: Errors::Group.levels["error"], handled: nil, at: Time.current)
    described_class.call(
      event_type: event_type, subject_type: "Errors::Group", subject_id: group.id,
      project_id: project.id, environment: "production", level: level, handled: handled, at: at
    )
  end

  describe "matching e consegna in-app" do
    it "crea una notifica in-app per il destinatario quando una regola matcha" do
      create(:alerting_rule, organization: organization, event_type: :error_new)
      expect { evaluate_error }
        .to change(Alerting::Notification.where(account: owner, via: :in_app), :count).by(1)
    end

    it "non crea nulla se nessuna regola matcha il tipo di evento" do
      create(:alerting_rule, organization: organization, event_type: :uptime_down)
      expect { evaluate_error }.not_to change(Alerting::Notification, :count)
    end

    it "regola scoped su un altro progetto non matcha" do
      other = create(:project, organization: organization)
      create(:alerting_rule, organization: organization, event_type: :error_new, project: other)
      expect { evaluate_error }.not_to change(Alerting::Notification, :count)
    end

    it "regola scoped sullo stesso progetto matcha" do
      create(:alerting_rule, organization: organization, event_type: :error_new, project: project)
      expect { evaluate_error }
        .to change(Alerting::Notification.where(via: :in_app), :count).by(1)
    end

    # CYRA-450 — regressione: l'avviso host fermo (org-scoped, subject = Agents::Host) deve arrivare in-app
    # al gestore dell'automazione. Copre l'intera catena regola → destinatari (for_agents) → contenuto →
    # notifica: senza agents_host_stale nell'enum di Alerting::Notification la consegna esploderebbe qui.
    it "consegna in-app l'avviso host fermo (agents_host_stale, org-scoped)" do
      host = create(:agent_host, organization: organization)
      create(:alerting_rule, organization: organization, event_type: :agents_host_stale)

      expect do
        described_class.call(event_type: "agents_host_stale", subject_type: "Agents::Host",
                             subject_id: host.id, project_id: nil, organization_id: organization.id)
      end.to change(Alerting::Notification.where(account: owner, via: :in_app), :count).by(1)
    end

    # CYRA-712/CYRA-875 — the whole chain rule → recipients → content → notification for the AI
    # alerts, which concern CloseYourIt itself and therefore reach only the gods.
    it "delivers the AI outage alert only to the god, never to the customer owner (CYRA-875)" do
      god = create(:account, god: true).tap { |a| create(:membership, account: a, organization: organization) }
      create(:alerting_rule, organization: organization, event_type: :ai_unavailable)

      described_class.call(event_type: "ai_unavailable", subject_type: "Organizations::Organization",
                           subject_id: organization.id, project_id: nil, organization_id: organization.id,
                           value: Integrations::Verify::INVALID_KEY)

      expect(Alerting::Notification.where(via: :in_app).pluck(:account_id)).to eq([ god.id ])
    end

    it "never sends a platform alert to the organization's external channels" do
      create(:membership, account: create(:account, god: true), organization: organization)
      allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ])
      rule = create(:alerting_rule, organization: organization, event_type: :ai_available)
      channel = create(:alerting_channel, organization: organization)
      create(:alerting_rule_channel, rule: rule, channel: channel)
      allow(Alerting::Deliver).to receive(:webhook)

      described_class.call(event_type: "ai_available", subject_type: "Organizations::Organization",
                           subject_id: organization.id, project_id: nil, organization_id: organization.id)

      expect(Alerting::Deliver).not_to have_received(:webhook)
    end

    it "delivers the recovery (ai_available) to the god as well, so the earlier alert is closed" do
      god = create(:account, god: true).tap { |a| create(:membership, account: a, organization: organization) }
      create(:alerting_rule, organization: organization, event_type: :ai_available)

      expect do
        described_class.call(event_type: "ai_available", subject_type: "Organizations::Organization",
                             subject_id: organization.id, project_id: nil, organization_id: organization.id)
      end.to change(Alerting::Notification.where(account: god, via: :in_app), :count).by(1)
      expect(Alerting::Notification.where(account: owner)).to be_empty
    end
  end

  describe "actor_id (esclusione dell'attore dell'evento, CYRA-147)" do
    it "non notifica l'account passato come actor_id (l'autore non si auto-notifica)" do
      create(:alerting_rule, organization: organization, event_type: :error_new)
      result = described_class.call(
        event_type: "error_new", subject_type: "Errors::Group", subject_id: group.id,
        project_id: project.id, environment: "production", level: Errors::Group.levels["error"],
        actor_id: owner.id
      )
      expect(result.value).to eq(0)
      expect(Alerting::Notification.where(account: owner)).not_to exist
    end

    it "senza actor_id l'account riceve normalmente (comportamento invariato)" do
      create(:alerting_rule, organization: organization, event_type: :error_new)
      expect { evaluate_error }
        .to change(Alerting::Notification.where(account: owner, via: :in_app), :count).by(1)
    end
  end

  describe "unhandled_only (CYRA-49: alert sui soli crash non gestiti)" do
    it "regola unhandled_only + crash non gestito (handled=false) → notifica" do
      create(:alerting_rule, organization: organization, event_type: :error_new, unhandled_only: true)
      expect { evaluate_error(handled: false) }
        .to change(Alerting::Notification.where(via: :in_app), :count).by(1)
    end

    it "regola unhandled_only + cattura volontaria (handled=true) → nessuna notifica" do
      create(:alerting_rule, organization: organization, event_type: :error_new, unhandled_only: true)
      expect { evaluate_error(handled: true) }.not_to change(Alerting::Notification, :count)
    end

    it "regola unhandled_only + handled sconosciuto (nil) → nessuna notifica (conservativo)" do
      create(:alerting_rule, organization: organization, event_type: :error_new, unhandled_only: true)
      expect { evaluate_error(handled: nil) }.not_to change(Alerting::Notification, :count)
    end

    it "regola normale (unhandled_only=false) scatta anche su una cattura volontaria (invariato)" do
      create(:alerting_rule, organization: organization, event_type: :error_new, unhandled_only: false)
      expect { evaluate_error(handled: true) }
        .to change(Alerting::Notification.where(via: :in_app), :count).by(1)
    end

    it "vale anche per error_spike: solo il crash non gestito notifica" do
      create(:alerting_rule, organization: organization, event_type: :error_spike, unhandled_only: true)
      expect { evaluate_error(event_type: "error_spike", handled: true) }.not_to change(Alerting::Notification, :count)
      expect { evaluate_error(event_type: "error_spike", handled: false) }
        .to change(Alerting::Notification.where(via: :in_app), :count).by(1)
    end
  end

  describe "error_spike (spike/surge di un errore già unresolved)" do
    it "una regola error_spike configurata → notifica in-app al destinatario" do
      create(:alerting_rule, organization: organization, event_type: :error_spike)
      expect { evaluate_error(event_type: "error_spike") }
        .to change(Alerting::Notification.where(account: owner, via: :in_app), :count).by(1)
    end

    it "rispetta il min_level della regola: evento sotto soglia → nessuna notifica" do
      create(:alerting_rule, organization: organization, event_type: :error_spike,
                             min_level: Errors::Group.levels["fatal"])
      expect { evaluate_error(event_type: "error_spike", level: Errors::Group.levels["warning"]) }
        .not_to change(Alerting::Notification, :count)
    end
  end

  describe "email" do
    it "accoda l'email quando la preferenza email è attiva" do
      create(:alerting_rule, organization: organization, event_type: :error_new)
      expect { evaluate_error }.to have_enqueued_mail(Alerting::AlertsMailer, :triggered)
    end

    it "non accoda email se email_enabled è falso (ma crea l'in-app)" do
      create(:alerting_rule, organization: organization, event_type: :error_new)
      create(:alerting_preference, account: owner, organization: organization, email_enabled: false)
      expect { evaluate_error }.not_to have_enqueued_mail(Alerting::AlertsMailer, :triggered)
      expect(Alerting::Notification.where(account: owner, via: :in_app)).to exist
    end
  end

  describe "anti-spam (throttle/dedup)" do
    it "due eventi nella stessa finestra → una sola notifica in-app" do
      create(:alerting_rule, organization: organization, event_type: :error_new, throttle_seconds: 300)
      now = Time.zone.at(1_700_000_000)
      evaluate_error(at: now)
      expect { evaluate_error(at: now + 60) }
        .not_to change(Alerting::Notification.where(via: :in_app), :count)
    end

    it "oltre la finestra di throttle → nuova notifica" do
      create(:alerting_rule, organization: organization, event_type: :error_new, throttle_seconds: 300)
      now = Time.zone.at(1_700_000_000)
      evaluate_error(at: now)
      expect { evaluate_error(at: now + 301) }
        .to change(Alerting::Notification.where(via: :in_app), :count).by(1)
    end
  end

  describe "cadenza per-notifica" do
    it "cadenza email off per l'evento → nessuna email, ma l'in-app è sempre consegnata" do
      create(:alerting_rule, organization: organization, event_type: :error_new)
      create(:alerting_preference, account: owner, organization: organization,
                                   email_cadences: { "error_new" => "off" })

      expect { evaluate_error }.not_to have_enqueued_mail(Alerting::AlertsMailer, :triggered)
      expect(Alerting::Notification.where(account: owner, via: :in_app)).to exist
      expect(Alerting::Notification.where(account: owner, via: :email)).not_to exist
    end

    it "cadenza email daily → riga email :queued col bucket, non inviata" do
      create(:alerting_rule, organization: organization, event_type: :error_new)
      create(:alerting_preference, account: owner, organization: organization,
                                   email_cadences: { "error_new" => "daily" })

      expect { evaluate_error }.not_to have_enqueued_mail(Alerting::AlertsMailer, :triggered)
      row = Alerting::Notification.find_by(account: owner, via: :email)
      expect(row).to be_status_queued
      expect(row).to be_digest_bucket_daily
    end
  end

  describe "quiet hours" do
    it "email viene trattenuta (:held), l'in-app è comunque consegnata" do
      create(:alerting_rule, organization: organization, event_type: :error_new)
      create(:alerting_preference, :quiet_nights, account: owner, organization: organization)
      evaluate_error(at: Time.utc(2026, 1, 15, 22, 0)) # Rome 23:00 → quiet
      expect(Alerting::Notification.where(account: owner, via: :in_app, status: :sent)).to exist
      expect(Alerting::Notification.where(account: owner, via: :email, status: :held)).to exist
    end
  end

  describe "min_level" do
    it "una regola fatal-only non scatta per un errore di livello error" do
      create(:alerting_rule, organization: organization, event_type: :error_new,
                             min_level: Errors::Group.levels["fatal"])
      expect { evaluate_error(level: Errors::Group.levels["error"]) }
        .not_to change(Alerting::Notification, :count)
    end

    it "una regola error-or-higher scatta per un errore fatal" do
      create(:alerting_rule, organization: organization, event_type: :error_new,
                             min_level: Errors::Group.levels["error"])
      expect { evaluate_error(level: Errors::Group.levels["fatal"]) }
        .to change(Alerting::Notification.where(via: :in_app), :count).by(1)
    end
  end

  describe "threshold_ms (regole metric_threshold)" do
    let(:metric_group) { create(:metric_group, project: project, kind: :performance_issue) }

    def evaluate_metric(duration_ms: nil)
      described_class.call(event_type: "metric_threshold", subject_type: "Metrics::Group",
                           subject_id: metric_group.id, project_id: project.id,
                           duration_ms: duration_ms)
    end

    it "regola senza threshold_ms scatta comunque (comportamento invariato)" do
      create(:alerting_rule, organization: organization, event_type: :metric_threshold)
      expect { evaluate_metric }.to change(Alerting::Notification.where(via: :in_app), :count).by(1)
    end

    it "sotto soglia (499 < 500) non scatta" do
      create(:alerting_rule, organization: organization, event_type: :metric_threshold, threshold_ms: 500)
      expect { evaluate_metric(duration_ms: 499) }.not_to change(Alerting::Notification, :count)
    end

    it "alla soglia esatta (500 = 500) scatta" do
      create(:alerting_rule, organization: organization, event_type: :metric_threshold, threshold_ms: 500)
      expect { evaluate_metric(duration_ms: 500) }
        .to change(Alerting::Notification.where(via: :in_app), :count).by(1)
    end

    it "oltre soglia (501 > 500) scatta" do
      create(:alerting_rule, organization: organization, event_type: :metric_threshold, threshold_ms: 500)
      expect { evaluate_metric(duration_ms: 501) }
        .to change(Alerting::Notification.where(via: :in_app), :count).by(1)
    end

    it "evento senza duration_ms: una regola con threshold_ms non scatta (conservativo)" do
      create(:alerting_rule, organization: organization, event_type: :metric_threshold, threshold_ms: 500)
      expect { evaluate_metric }.not_to change(Alerting::Notification, :count)
    end

    it "threshold_ms su una regola NON metric_threshold è ignorato" do
      create(:alerting_rule, organization: organization, event_type: :error_new, threshold_ms: 500)
      expect { evaluate_error }.to change(Alerting::Notification.where(via: :in_app), :count).by(1)
    end

    # CYRA-39: i verdetti "a conteggio" pesano per numero di occorrenze, non per durata (il campione
    # arriva con duration_ms=0). La soglia occorrenze è già applicata a monte (Metrics::Ingest::Record);
    # il gate threshold_ms NON deve sopprimere l'alert per questi subtype.
    describe "subtype a conteggio (count-based)" do
      def evaluate_count_based(subtype:, duration_ms: 0.0)
        group = create(:metric_group, project: project, kind: :performance_issue, subtype: subtype)
        described_class.call(event_type: "metric_threshold", subject_type: "Metrics::Group",
                             subject_id: group.id, project_id: project.id, duration_ms: duration_ms)
      end

      Metrics::Group::COUNT_BASED_SUBTYPES.each do |subtype|
        it "#{subtype} con duration_ms=0 scatta nonostante threshold_ms=300" do
          create(:alerting_rule, organization: organization, event_type: :metric_threshold, threshold_ms: 300)
          expect { evaluate_count_based(subtype: subtype) }
            .to change(Alerting::Notification.where(via: :in_app), :count).by(1)
        end
      end

      it "duration_ms nil (non applicabile) su un subtype a conteggio scatta comunque" do
        create(:alerting_rule, organization: organization, event_type: :metric_threshold, threshold_ms: 300)
        expect { evaluate_count_based(subtype: "repeated_http", duration_ms: nil) }
          .to change(Alerting::Notification.where(via: :in_app), :count).by(1)
      end

      it "un subtype duration-based (slow_request) con duration 0 sotto soglia NON scatta" do
        create(:alerting_rule, organization: organization, event_type: :metric_threshold, threshold_ms: 300)
        expect { evaluate_count_based(subtype: "slow_request") }
          .not_to change(Alerting::Notification, :count)
      end
    end
  end

  # CYRA-55: i log error/fatal generavano ingest ma nessun alert (osservabilità write-only). Una regola
  # log_alert li valuta come gli errori, con throttle per (progetto, livello) — lo stream è append-only,
  # ogni entry è un subject nuovo, quindi il dedup NON può basarsi sull'id della singola entry.
  describe "log_alert (log error/fatal)" do
    let(:entry) { create(:log_entry, project: project, level: :fatal, message: "payment gateway unreachable") }

    def evaluate_log(subject: entry, level: Logs::Entry.levels["fatal"], at: Time.current)
      described_class.call(
        event_type: "log_alert", subject_type: "Logs::Entry", subject_id: subject.id,
        project_id: project.id, environment: "production", level: level, at: at
      )
    end

    it "una regola log_alert configurata → notifica in-app al destinatario" do
      create(:alerting_rule, organization: organization, event_type: :log_alert)
      expect { evaluate_log }
        .to change(Alerting::Notification.where(account: owner, via: :in_app), :count).by(1)
    end

    it "il subject della notifica è la Logs::Entry (link alla riga di log)" do
      create(:alerting_rule, organization: organization, event_type: :log_alert)
      evaluate_log
      notification = Alerting::Notification.find_by(account: owner, via: :in_app)
      expect(notification.subject).to eq(entry)
    end

    it "rispetta il min_level: una regola fatal-only non scatta per un log di livello error" do
      create(:alerting_rule, organization: organization, event_type: :log_alert,
                             min_level: Logs::Entry.levels["fatal"])
      expect { evaluate_log(level: Logs::Entry.levels["error"]) }
        .not_to change(Alerting::Notification, :count)
    end

    it "una regola error-or-higher scatta per un log fatal" do
      create(:alerting_rule, organization: organization, event_type: :log_alert,
                             min_level: Logs::Entry.levels["error"])
      expect { evaluate_log(level: Logs::Entry.levels["fatal"]) }
        .to change(Alerting::Notification.where(via: :in_app), :count).by(1)
    end

    it "throttle per (progetto, livello): due log fatal nella stessa finestra → una sola notifica" do
      create(:alerting_rule, organization: organization, event_type: :log_alert, throttle_seconds: 300)
      other = create(:log_entry, project: project, level: :fatal, message: "again")
      now = Time.zone.at(1_700_000_000)
      evaluate_log(subject: entry, at: now)
      expect { evaluate_log(subject: other, at: now + 60) }
        .not_to change(Alerting::Notification.where(via: :in_app), :count)
    end

    it "livelli diversi non si throttlano a vicenda (un fatal e un error → due notifiche)" do
      create(:alerting_rule, organization: organization, event_type: :log_alert, throttle_seconds: 300)
      err = create(:log_entry, project: project, level: :error, message: "err")
      now = Time.zone.at(1_700_000_000)
      evaluate_log(subject: entry, level: Logs::Entry.levels["fatal"], at: now)
      expect { evaluate_log(subject: err, level: Logs::Entry.levels["error"], at: now + 60) }
        .to change(Alerting::Notification.where(via: :in_app), :count).by(1)
    end
  end

  describe "uptime" do
    it "uptime_down crea una notifica per l'incident (match environment_id)" do
      monitor = create(:uptime_monitor, project: project)
      incident = create(:uptime_incident, monitor: monitor)
      create(:alerting_rule, organization: organization, event_type: :uptime_down)
      expect do
        described_class.call(event_type: "uptime_down", subject_type: "Uptime::Incident",
                             subject_id: incident.id, project_id: project.id,
                             environment_id: monitor.environment_id)
      end.to change(Alerting::Notification.where(via: :in_app), :count).by(1)
    end
  end

  describe "scoping environment e level" do
    it "regola scoped su environment che combacia (per code) matcha l'errore" do
      env = create(:environment, organization: organization, code: "production")
      create(:alerting_rule, organization: organization, event_type: :error_new, environment: env)
      expect { evaluate_error }.to change(Alerting::Notification.where(via: :in_app), :count).by(1)
    end

    it "regola scoped su environment diverso non matcha" do
      env = create(:environment, organization: organization, code: "staging")
      create(:alerting_rule, organization: organization, event_type: :error_new, environment: env)
      expect { evaluate_error }.not_to change(Alerting::Notification, :count)
    end

    it "evento errore senza livello: una regola con min_level non scatta" do
      create(:alerting_rule, organization: organization, event_type: :error_new,
                             min_level: Errors::Group.levels["warning"])
      expect { evaluate_error(level: nil) }.not_to change(Alerting::Notification, :count)
    end
  end

  describe "robustezza" do
    it "subject inesistente → no-op" do
      create(:alerting_rule, organization: organization, event_type: :error_new)
      expect do
        described_class.call(event_type: "error_new", subject_type: "Errors::Group",
                             subject_id: SecureRandom.uuid, project_id: project.id,
                             environment: "production", level: Errors::Group.levels["error"])
      end.not_to change(Alerting::Notification, :count)
    end

    it "progetto inesistente → no-op (Result.ok 0)" do
      create(:alerting_rule, organization: organization, event_type: :error_new)
      result = described_class.call(event_type: "error_new", subject_type: "Errors::Group",
                                    subject_id: group.id, project_id: SecureRandom.uuid,
                                    environment: "production", level: Errors::Group.levels["error"])
      expect(result).to be_ok
      expect(result.value).to eq(0)
    end
  end

  describe "in-app sempre attiva (non disattivabile)" do
    it "l'in-app è consegnata anche con il vecchio flag in_app_enabled = false" do
      create(:alerting_rule, organization: organization, event_type: :error_new)
      create(:alerting_preference, account: owner, organization: organization, in_app_enabled: false)
      evaluate_error
      expect(Alerting::Notification.where(account: owner, via: :in_app)).to exist
    end
  end

  describe "canale Telegram per-utente" do
    it "telegram acceso + account collegato → invia il DM e crea la riga via telegram" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return("999:xyz")
      stub = stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage").to_return(status: 200)
      owner.update!(telegram_chat_id: "500")
      create(:alerting_rule, organization: organization, event_type: :error_new)
      create(:alerting_preference, account: owner, organization: organization, telegram_enabled: true)

      evaluate_error

      expect(stub).to have_been_requested
      expect(Alerting::Notification.where(account: owner, via: :telegram)).to exist
    end

    it "telegram spento → nessuna riga telegram" do
      owner.update!(telegram_chat_id: "500")
      create(:alerting_rule, organization: organization, event_type: :error_new)
      create(:alerting_preference, account: owner, organization: organization, telegram_enabled: false)

      evaluate_error

      expect(Alerting::Notification.where(account: owner, via: :telegram)).not_to exist
    end

    # CYRA-853 — la mail è la riserva di Telegram, non un secondo invio dello stesso avviso.
    describe "mail come riserva" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return("999:xyz")
        owner.update!(telegram_chat_id: "500")
        create(:alerting_rule, organization: organization, event_type: :error_new)
        create(:alerting_preference, account: owner, organization: organization, telegram_enabled: true)
      end

      it "Telegram consegnato → la mail dello stesso avviso non parte" do
        stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage").to_return(status: 200)

        evaluate_error

        expect(Alerting::Notification.where(account: owner, via: :telegram).sole).to be_status_sent
        expect(Alerting::Notification.where(account: owner, via: :email)).not_to exist
      end

      it "Telegram fallito → parte la mail" do
        stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage").to_return(status: 500)

        evaluate_error

        expect(Alerting::Notification.where(account: owner, via: :telegram).sole).to be_status_failed
        expect(Alerting::Notification.where(account: owner, via: :email)).to exist
      end

      it "il secondo evento nella stessa finestra non manda la mail che il primo aveva risparmiato" do
        stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage").to_return(status: 200)

        evaluate_error
        evaluate_error

        expect(Alerting::Notification.where(account: owner, via: :email)).not_to exist
      end
    end
  end

  # CYRA-852 — l'owner col gruppo con argomenti riceve l'avviso lì: non in privato, non per mail.
  describe "gruppo Telegram dell'owner" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return("999:xyz")
      Alerting::TelegramGroup.create!(organization: organization, account: owner, chat_id: "-100", topics: { "errors" => 4 })
      create(:alerting_rule, organization: organization, event_type: :error_new)
      create(:alerting_preference, account: owner, organization: organization, telegram_enabled: true)
    end

    it "anche senza chat personale collegata, l'avviso va nell'argomento del gruppo e la mail non parte" do
      to_group = stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage")
                 .with { |req| JSON.parse(req.body).values_at("chat_id", "message_thread_id") == [ "-100", 4 ] }
                 .to_return(status: 200)

      evaluate_error

      expect(to_group).to have_been_requested
      expect(Alerting::Notification.where(account: owner, via: :telegram).sole).to be_status_sent
      expect(Alerting::Notification.where(account: owner, via: :email)).not_to exist
    end
  end

  describe "match per environment_id (eventi uptime)" do
    let(:monitor) { create(:uptime_monitor, project: project) }
    let(:incident) { create(:uptime_incident, monitor: monitor) }

    def evaluate_uptime
      described_class.call(event_type: "uptime_down", subject_type: "Uptime::Incident",
                           subject_id: incident.id, project_id: project.id,
                           environment_id: monitor.environment_id)
    end

    it "regola scoped sullo STESSO environment (match per id) → notifica" do
      create(:alerting_rule, organization: organization, event_type: :uptime_down,
                             environment_id: monitor.environment_id)
      expect { evaluate_uptime }.to change(Alerting::Notification.where(via: :in_app), :count).by(1)
    end

    it "regola scoped su un environment DIVERSO (id) → nessuna notifica" do
      other = create(:environment, organization: organization, code: "staging")
      create(:alerting_rule, organization: organization, event_type: :uptime_down, environment_id: other.id)
      expect { evaluate_uptime }.not_to change(Alerting::Notification, :count)
    end
  end

  describe "errore senza environment vs regola scoped a environment" do
    it "regola con environment + evento SENZA environment → nessun match (return false)" do
      env = create(:environment, organization: organization, code: "production")
      create(:alerting_rule, organization: organization, event_type: :error_new, environment: env)
      result = described_class.call(event_type: "error_new", subject_type: "Errors::Group",
                                    subject_id: group.id, project_id: project.id,
                                    environment: nil, level: Errors::Group.levels["error"])
      expect(result.value).to eq(0)
    end
  end

  describe "canali esterni della regola" do
    let(:rule) { create(:alerting_rule, organization: organization, event_type: :error_new) }
    let(:channel) { create(:alerting_channel, organization: organization) }

    before do
      allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ])
      create(:alerting_rule_channel, rule:, channel:)
      # Il throttle canale usa la cache atomica: memoria pulita per ogni example.
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    end

    it "consegna sul webhook agganciato alla regola" do
      stub = stub_request(:post, "https://hooks.example.test/cyi").to_return(status: 200)

      evaluate_error

      expect(stub).to have_been_requested
    end

    it "throttle: la stessa (regola, canale, evento, subject) nella finestra consegna UNA volta" do
      stub = stub_request(:post, "https://hooks.example.test/cyi").to_return(status: 200)

      # Epoch FISSO (non Time.current): il bucket throttle è `at.to_i / throttle_seconds` — con un `at`
      # casuale i due eventi possono cadere ai due lati di un boundary (~1/throttle_seconds) → 2 consegne
      # invece di 1 (flaky in CI). 1_700_000_000 non è su un boundary.
      at = Time.zone.at(1_700_000_000)
      evaluate_error(at: at)
      evaluate_error(at: at + 1.second)

      expect(stub).to have_been_requested.once
    end

    it "canale disabilitato → nessuna consegna" do
      channel.update!(enabled: false)
      stub = stub_request(:post, "https://hooks.example.test/cyi").to_return(status: 200)

      evaluate_error

      expect(stub).not_to have_been_requested
    end

    it "il fallimento del webhook non blocca le consegne umane" do
      stub_request(:post, "https://hooks.example.test/cyi").to_timeout

      expect { evaluate_error }
        .to change(Alerting::Notification.where(account: owner, via: :in_app), :count).by(1)
    end
  end

  describe "localizzazione per-destinatario (snapshot notifiche)" do
    it "salva il titolo di ogni notifica nella lingua del rispettivo destinatario" do
      owner.update!(locale: "en")
      # Secondo destinatario con accesso diretto al progetto (un'org ha un solo owner): member + ProjectMembership.
      italiano = create(:account, locale: "it")
      create(:membership, account: italiano, organization: organization, role: :member)
      create(:project_membership, account: italiano, project: project)
      create(:alerting_rule, organization: organization, event_type: :error_new)

      evaluate_error

      en_title = Alerting::Notification.find_by(account: owner, via: :in_app).title
      it_title = Alerting::Notification.find_by(account: italiano, via: :in_app).title
      expected_en = I18n.with_locale(:en) { Alerting::Content.for(event_type: "error_new", subject: group).title }
      expected_it = I18n.with_locale(:it) { Alerting::Content.for(event_type: "error_new", subject: group).title }
      expect(en_title).to eq(expected_en)
      expect(it_title).to eq(expected_it)
      expect(it_title).not_to eq(en_title) # le due lingue producono davvero titoli diversi
    end
  end
end
