# frozen_string_literal: true

require "rails_helper"

# Branch org-scoped di Evaluate (eventi server_*: nessun progetto, recipients per permesso org).
RSpec.describe Alerting::Evaluate do
  include ActiveJob::TestHelper

  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:host) { create(:server_host, organization: org, name: "apps", cpu_pct: 95.0) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def evaluate(event_type:, value: nil)
    described_class.call(
      event_type: event_type, subject_type: "Servers::Host", subject_id: host.id,
      project_id: nil, organization_id: org.id, value: value
    )
  end

  it "server_down con regola org → notifica in-app all'owner con project nil" do
    create(:alerting_rule, organization: org, event_type: :server_down, name: "Down")

    result = evaluate(event_type: "server_down")

    expect(result.value).to be > 0
    notification = Alerting::Notification.find_by(account: owner, event_type: "server_down")
    expect(notification).to be_present
    expect(notification.subject).to eq(host)
    expect(notification.project).to be_nil
    expect(notification.organization).to eq(org)
  end

  it "senza regole per l'evento → nessuna consegna" do
    expect(evaluate(event_type: "server_down").value).to eq(0)
  end

  # CYRA-519 — l'eccezione per-macchina: la regola resta accesa per la flotta, ma su quella macchina
  # tace. Prima l'unica scelta davanti a un falso allarme ricorrente era spegnerla per tutti.
  describe "regola silenziata su una macchina" do
    it "non avvisa sulla macchina esclusa" do
      rule = create(:alerting_rule, organization: org, event_type: :server_down, name: "Down")
      Alerting::RuleHostExclusion.create!(rule:, host:)

      expect(evaluate(event_type: "server_down").value).to eq(0)
    end

    it "continua ad avvisare su tutte le altre" do
      rule = create(:alerting_rule, organization: org, event_type: :server_down, name: "Down")
      altra = create(:server_host, organization: org, name: "db")
      Alerting::RuleHostExclusion.create!(rule:, host: altra)

      expect(evaluate(event_type: "server_down").value).to be > 0
    end

    it "silenzia solo la regola esclusa, non le altre sullo stesso evento" do
      muta = create(:alerting_rule, organization: org, event_type: :server_down, name: "Rumorosa")
      create(:alerting_rule, organization: org, event_type: :server_down, name: "Buona")
      Alerting::RuleHostExclusion.create!(rule: muta, host:)

      expect(evaluate(event_type: "server_down").value).to be > 0
    end

    # Scenario 3 del ticket: chi non imposta nessuna eccezione non vede cambiare niente.
    it "senza eccezioni l'avviso arriva come prima" do
      create(:alerting_rule, organization: org, event_type: :server_down, name: "Down")

      expect(evaluate(event_type: "server_down").value).to be > 0
    end
  end

  it "regola di un'altra org non matcha" do
    create(:alerting_rule, event_type: :server_down, name: "Altrui")

    expect(evaluate(event_type: "server_down").value).to eq(0)
  end

  it "organization sparita → no-op" do
    result = described_class.call(
      event_type: "server_down", subject_type: "Servers::Host", subject_id: host.id,
      project_id: nil, organization_id: SecureRandom.uuid
    )

    expect(result.value).to eq(0)
  end

  describe "soglie (server_cpu)" do
    before { create(:alerting_rule, organization: org, event_type: :server_cpu, name: "CPU", threshold: 90) }

    it "valore alla soglia → scatta (90 >= 90)" do
      expect(evaluate(event_type: "server_cpu", value: 90.0).value).to be > 0
    end

    it "valore sotto soglia → non scatta" do
      expect(evaluate(event_type: "server_cpu", value: 89.9).value).to eq(0)
    end

    it "senza valore nell'evento → conservativo, non scatta" do
      expect(evaluate(event_type: "server_cpu").value).to eq(0)
    end

    # CYRA-458: la soglia per-macchina (sull'host) sostituisce quella della regola org, così l'avviso
    # scatta sullo STESSO limite che l'UI mostra accanto al valore.
    context "con soglia per-macchina sull'host" do
      before { host.update!(cpu_threshold: 95) }

      it "il valore fra soglia-regola e soglia-macchina non scatta (90 < 95)" do
        expect(evaluate(event_type: "server_cpu", value: 90.0).value).to eq(0)
      end

      it "scatta quando il valore raggiunge la soglia della macchina (95 >= 95)" do
        expect(evaluate(event_type: "server_cpu", value: 95.0).value).to be > 0
      end
    end

    # CYRA-1209: anche una soglia per-macchina PIÙ BASSA di quella della regola vale per questa macchina.
    context "con soglia per-macchina più bassa di quella della regola" do
      before { host.update!(cpu_threshold: 70) }

      it "il valore fra soglia-macchina e soglia-regola scatta (78 >= 70)" do
        expect(evaluate(event_type: "server_cpu", value: 78.0).value).to be > 0
      end

      it "sotto la soglia della macchina non scatta (60 < 70)" do
        expect(evaluate(event_type: "server_cpu", value: 60.0).value).to eq(0)
      end
    end
  end

  # CYRA-181: gli eventi del database passano dallo stesso branch org-scoped (subject = host).
  describe "eventi database" do
    before do
      host.update!(database_snapshot: {
        "engine" => "postgresql", "reachable" => false,
        "connections" => { "total" => 96, "max" => 100 },
        "replication" => { "lag_seconds" => 42.5 }
      })
    end

    it "server_db_down con regola org → notifica in-app con snapshot leggibile" do
      create(:alerting_rule, organization: org, event_type: :server_db_down, name: "DB down")

      expect(evaluate(event_type: "server_db_down").value).to be > 0
      notification = Alerting::Notification.find_by(account: owner, event_type: "server_db_down")
      expect(notification.subject).to eq(host)
      expect(notification.project).to be_nil
      expect(notification.title).to include("apps")
      expect(notification.body).to be_present
    end

    it "server_db_connections rispetta la soglia della regola" do
      create(:alerting_rule, organization: org, event_type: :server_db_connections, name: "Conn", threshold: 90)

      expect(evaluate(event_type: "server_db_connections", value: 96.0).value).to be > 0
      expect(evaluate(event_type: "server_db_connections", value: 80.0).value).to eq(0)
    end

    it "server_replication_lag rispetta la soglia in secondi" do
      create(:alerting_rule, organization: org, event_type: :server_replication_lag, name: "Lag", threshold: 30)

      expect(evaluate(event_type: "server_replication_lag", value: 42.5).value).to be > 0
      expect(evaluate(event_type: "server_replication_lag", value: 1.0).value).to eq(0)
    end
  end

  # CYRA-248: container spariti dal push → avviso org-scoped con conteggio+macchina; il nome caduto
  # resta consultabile in details (CYRA-323).
  describe "server_container_down" do
    it "notifica in-app con conteggio+macchina, il nome caduto in details" do
      host.update!(container_outage: { "names" => %w[redis] })
      create(:alerting_rule, organization: org, event_type: :server_container_down, name: "Container down")

      expect(evaluate(event_type: "server_container_down").value).to be > 0
      notification = Alerting::Notification.find_by(account: owner, event_type: "server_container_down")
      expect(notification.subject).to eq(host)
      expect(notification.project).to be_nil
      expect(notification.title).to include("apps")
      expect(notification.body).to eq("1 container down on apps.")
      expect(notification.details).to eq(%w[redis])
    end

    it "motore giù (tutti spariti insieme): un solo avviso col motore che non risponde" do
      host.update!(container_outage: { "engine_down" => true })
      create(:alerting_rule, organization: org, event_type: :server_container_down, name: "Container down")

      expect(evaluate(event_type: "server_container_down").value).to be > 0
      notification = Alerting::Notification.find_by(account: owner, event_type: "server_container_down")
      expect(notification.body).to be_present
    end
  end

  it "cadenza email off per l'evento → nessuna email, ma l'in-app resta" do
    create(:alerting_rule, organization: org, event_type: :server_down, name: "Down")
    create(:alerting_preference, account: owner, organization: org,
                                 email_cadences: { "server_down" => "off" })

    evaluate(event_type: "server_down")

    expect(Alerting::Notification.where(account: owner, event_type: "server_down", via: :in_app).count).to eq(1)
    expect(Alerting::Notification.where(account: owner, event_type: "server_down", via: :email).count).to eq(0)
  end

  # CYRA-1256 — the return under threshold uses the measurement's rule, without comparing thresholds.
  describe "server_threshold_recovered" do
    def recover(metric:, value: 70.0)
      described_class.call(
        event_type: "server_threshold_recovered", subject_type: "Servers::Host", subject_id: host.id,
        project_id: nil, organization_id: org.id, value: value, metric: metric
      )
    end

    let!(:rule) { create(:alerting_rule, organization: org, event_type: :server_disk, name: "Disk", threshold: 80) }

    it "reaches the people of the measurement's rule, even with the value under its threshold" do
      expect(recover(metric: "server_disk").value).to be > 0

      notification = Alerting::Notification.find_by(account: owner, event_type: "server_threshold_recovered", via: :in_app)
      expect(notification.rule).to eq(rule)
      expect(notification.subject).to eq(host)
      expect(notification.title).to include("apps")
      expect(notification.body).to include("70%")
    end

    # CYRA-1227 — the channel is reached by the queued job, which accepts the measurement's rule (WI-4).
    it "reaches the measurement rule's external channels" do
      allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ])
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      channel = create(:alerting_channel, organization: org)
      create(:alerting_rule_channel, rule: rule, channel: channel)
      allow(Alerting::Deliver).to receive(:webhook).and_return(Result.ok(nil))

      perform_enqueued_jobs(only: Alerting::DeliverChannelJob) { recover(metric: "server_disk") }

      expect(Alerting::Deliver).to have_received(:webhook)
        .with(hash_including(channel: channel, event_type: "server_threshold_recovered"))
    end

    it "ignores the rules of other measurements and unknown measurements" do
      expect(recover(metric: "server_cpu").value).to eq(0)
      expect(recover(metric: "server_down").value).to eq(0)
      expect(recover(metric: nil).value).to eq(0)
    end

    it "stays silent on a host excluded from the rule" do
      Alerting::RuleHostExclusion.create!(rule:, host:)

      expect(recover(metric: "server_disk").value).to eq(0)
    end

    it "does not collapse the returns of two measurements of the same host" do
      create(:alerting_rule, organization: org, event_type: :server_cpu, name: "CPU", threshold: 90)

      recover(metric: "server_disk")
      recover(metric: "server_cpu", value: 40.0)

      expect(Alerting::Notification.where(account: owner, event_type: "server_threshold_recovered", via: :in_app).count).to eq(2)
    end
  end

  # CYRA-1256 — a crossing is a state change remembered on the host: its breach identity replaces the
  # rule's time window, and `above` keeps the rules already told about the open breach quiet.
  describe "threshold crossing with a breach identity" do
    def cross(value:, breach:, above: nil, at: Time.zone.parse("2026-07-02T10:00:10Z"))
      described_class.call(
        event_type: "server_disk", subject_type: "Servers::Host", subject_id: host.id,
        project_id: nil, organization_id: org.id, value: value, breach: breach, above: above, at: at
      )
    end

    def crossings(rule)
      Alerting::Notification.where(account: owner, event_type: "server_disk", via: :in_app, rule: rule)
    end

    let!(:rule) do
      create(:alerting_rule, organization: org, event_type: :server_disk, name: "Disk", threshold: 80, throttle_seconds: 300)
    end

    it "delivers a second crossing inside the same throttle window when it is a new breach" do
      allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ])
      channel = create(:alerting_channel, organization: org)
      create(:alerting_rule_channel, rule: rule, channel: channel)
      allow(Alerting::Deliver).to receive(:webhook).and_return(Result.ok(nil))
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

      perform_enqueued_jobs(only: Alerting::DeliverChannelJob) do # CYRA-1227: channels go through the queue
        cross(value: 95.0, breach: "2026-07-02T10:00:00Z@80.0")
        cross(value: 95.0, breach: "2026-07-02T10:01:00Z@80.0", at: Time.zone.parse("2026-07-02T10:01:10Z"))
      end

      expect(crossings(rule).count).to eq(2)
      expect(Alerting::Deliver).to have_received(:webhook).twice
    end

    it "still collapses a retried job of the same breach, even in a later window" do
      cross(value: 95.0, breach: "2026-07-02T10:00:00Z@80.0")
      cross(value: 95.0, breach: "2026-07-02T10:00:00Z@80.0", at: Time.zone.parse("2026-07-02T10:20:00Z"))

      expect(crossings(rule).count).to eq(1)
    end

    it "on a rise during the breach reaches only the rules above the level already alerted" do
      critical = create(:alerting_rule, organization: org, event_type: :server_disk, name: "Disk critical", threshold: 95)

      cross(value: 96.0, breach: "2026-07-02T10:00:00Z@95.0", above: 80.0)

      expect(crossings(rule)).to be_empty
      expect(crossings(critical).count).to eq(1)
    end
  end

  it "throttle: due eventi nella stessa finestra → una sola notifica" do
    create(:alerting_rule, organization: org, event_type: :server_down, name: "Down", throttle_seconds: 300)

    evaluate(event_type: "server_down")
    evaluate(event_type: "server_down")

    expect(Alerting::Notification.where(account: owner, event_type: "server_down", via: :in_app).count).to eq(1)
  end
end
