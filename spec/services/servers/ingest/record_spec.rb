# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::Ingest::Record do
  include ActiveJob::TestHelper

  let(:payload) { JSON.parse(Rails.root.join("spec/fixtures/servers/agent_payload.json").read) }
  let(:host) { create(:server_host, fingerprint: payload["fingerprint"]) }

  # Il recorded_at della fixture è fisso: congela il tempo poco dopo, o il clamp anti-skew scatta.
  before { travel_to Time.zone.parse("2026-07-02T10:05:00Z") }

  it "aggiorna lo snapshot dell'host e lo marca up" do
    described_class.call(host:, payload:)

    host.reload
    expect(host.status_up?).to be(true)
    expect(host.hostname).to eq("apps-staging")
    expect(host.os_name).to eq("Ubuntu 24.04.2 LTS")
    expect(host.agent_version).to eq("0.1.0")
    expect(host.last_seen_at).to eq(Time.zone.parse("2026-07-02T10:00:00Z"))
    expect(host.cpu_pct).to eq(12.34)
    expect(host.mem_pct).to eq(39.9)
    expect(host.disk_pct).to eq(54.68)
    expect(host.temp_max).to eq(48.5)
    expect(host.uptime_seconds).to eq(864_000)
    expect(host.services_total).to eq(42)
    expect(host.services_failed).to eq(1)
    expect(host.containers_count).to eq(2)
    expect(host.systemd_services.length).to eq(2)
    expect(host.smart_data).to have_key("nvme0")
    expect(host.failed_services).to eq(%w[backup.service])
    expect(host.resource_pressure.dig("data_volume_disk", "mountpoint")).to eq("/mnt/data")
  end

  it "inserisce il campione con hot columns e il set container" do
    expect { described_class.call(host:, payload:) }
      .to change(Servers::Sample, :count).by(1)
      .and change(Servers::ContainerSample, :count).by(2)

    sample = Servers::Sample.last
    expect(sample.host).to eq(host)
    expect(sample.organization_id).to eq(host.organization_id)
    expect(sample.recorded_at).to eq(Time.zone.parse("2026-07-02T10:00:00Z"))
    expect(sample.cpu_pct).to eq(12.34)
    expect(sample.db_connection_usage_pct).to eq(44.21)
    expect(sample.data_volume_disk_pct).to eq(40.2)
    expect(sample.inode_pct).to eq(75.0)
    expect(sample.payload["temps"]).to be_present

    container = Servers::ContainerSample.order(:name).first
    expect(container.name).to eq("closeyourit-web")
    expect(container.health_healthy?).to be(true)
    expect(container.container_id).to eq("abcdef123456")
    expect(container.running).to be(true)
    expect(container.restart_count).to eq(2)
  end

  it "è idempotente sul retry (stesso recorded_at): nessun duplicato, niente container doppi" do
    described_class.call(host:, payload:)

    expect { described_class.call(host:, payload:) }
      .to change(Servers::Sample, :count).by(0)
      .and change(Servers::ContainerSample, :count).by(0)
  end

  describe "alerting post-commit" do
    it "host down → push → server_up" do
      host.update!(status: :down)

      expect { described_class.call(host:, payload:) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_up", subject_id: host.id,
                             organization_id: host.organization_id, project_id: nil))
    end

    it "primo push (pending) NON genera server_up" do
      expect { described_class.call(host:, payload:) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_up"))
    end

    it "nuovo servizio failed → server_service_failed; già noto → silenzio" do
      expect { described_class.call(host:, payload:) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_service_failed"))

      # secondo push con lo stesso failed già registrato sul host → nessun nuovo alert
      payload["recorded_at"] = "2026-07-02T10:01:00Z"
      expect { described_class.call(host: host.reload, payload:) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_service_failed"))
    end

    # CYRA-678 — una unit esclusa per-host non fa scattare l'avviso, ma resta nello stato raccolto.
    it "unit failed esclusa dai pattern → nessun server_service_failed, stato veritiero" do
      host.update!(ignored_service_patterns: [ "backup" ])

      expect { described_class.call(host:, payload:) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_service_failed"))

      expect(host.reload.failed_services).to eq(%w[backup.service])
    end

    it "SMART passed→failed → server_smart_failing (solo alla transizione)" do
      described_class.call(host:, payload:)

      failing = payload.deep_dup
      failing["recorded_at"] = "2026-07-02T10:01:00Z"
      failing["smart"]["nvme0"]["s"] = "FAILED"
      expect { described_class.call(host: host.reload, payload: failing) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_smart_failing"))

      failing2 = failing.deep_dup
      failing2["recorded_at"] = "2026-07-02T10:02:00Z"
      expect { described_class.call(host: host.reload, payload: failing2) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_smart_failing"))
    end

    # CYRA-676 — transizione nessuno→qualcuno, come server_smart_failing: il conteggio che sale non
    # ri-avvisa, il -1/assente (agent vecchio o OS non-apt) non valuta nulla.
    describe "aggiornamenti di sicurezza" do
      it "nessuno→qualcuno → server_security_updates col conteggio" do
        expect { described_class.call(host:, payload:) }
          .to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "server_security_updates", value: 3.0))
      end

      it "conteggio già noto (anche se sale) → silenzio" do
        described_class.call(host:, payload:)

        risen = payload.deep_dup
        risen["recorded_at"] = "2026-07-02T10:01:00Z"
        risen["host"]["security_updates_available"] = 5
        expect { described_class.call(host: host.reload, payload: risen) }
          .not_to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "server_security_updates"))
      end

      it "valore sconosciuto (-1) → nessuna valutazione" do
        unknown = payload.deep_dup
        unknown["host"]["security_updates_available"] = -1
        expect { described_class.call(host:, payload: unknown) }
          .not_to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "server_security_updates"))
      end

      it "tornati a zero e poi ricomparsi → nuovo avviso" do
        described_class.call(host:, payload:)

        cleared = payload.deep_dup
        cleared["recorded_at"] = "2026-07-02T10:01:00Z"
        cleared["host"]["security_updates_available"] = 0
        described_class.call(host: host.reload, payload: cleared)

        back = payload.deep_dup
        back["recorded_at"] = "2026-07-02T10:02:00Z"
        back["host"]["security_updates_available"] = 1
        expect { described_class.call(host: host.reload, payload: back) }
          .to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "server_security_updates", value: 1.0))
      end
    end

    # CYRA-676 — il riarmo dell'avviso «dati fermi»: il primo dato fresco azzera la memoria della
    # notifica, un dato ancora vecchio (backlog in smaltimento) la lascia armata.
    describe "riarmo silent_alerted_at" do
      it "dato fresco → azzera silent_alerted_at" do
        host.update!(silent_alerted_at: 5.minutes.ago)

        described_class.call(host:, payload:)
        expect(host.reload.silent_alerted_at).to be_nil
      end

      it "dato ancora vecchio → la memoria resta" do
        host.update!(silent_alerted_at: 5.minutes.ago)

        old_data = payload.deep_dup
        old_data["recorded_at"] = (Time.current - Servers::Constants::SILENT_ALERT_AFTER_SECONDS.seconds - 60).iso8601
        described_class.call(host:, payload: old_data)
        expect(host.reload.silent_alerted_at).to be_present
      end
    end

    describe "soglie" do
      it "regola cpu sotto il valore misurato → server_cpu col valore" do
        create(:alerting_rule, organization: host.organization, event_type: :server_cpu,
               name: "CPU alta", threshold: 10)

        expect { described_class.call(host:, payload:) }
          .to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "server_cpu", value: 12.34))
      end

      it "regola cpu sopra il valore misurato → nessun job (pre-check)" do
        create(:alerting_rule, organization: host.organization, event_type: :server_cpu,
               name: "CPU alta", threshold: 90)

        expect { described_class.call(host:, payload:) }
          .not_to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "server_cpu"))
      end

      it "regola disabled o di un'altra org non conta" do
        create(:alerting_rule, :disabled, organization: host.organization,
               event_type: :server_cpu, name: "off", threshold: 1)
        create(:alerting_rule, event_type: :server_cpu, name: "altrui", threshold: 1)

        expect { described_class.call(host:, payload:) }
          .not_to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "server_cpu"))
      end
    end

    it "host paused: registra i dati ma resta paused e non avvisa" do
      host.update!(status: :paused, failed_services: [])

      expect { described_class.call(host:, payload:) }
        .to change(Servers::Sample, :count).by(1)

      expect(host.reload.status_paused?).to be(true)
      expect(enqueued_jobs.select { |j| j["job_class"] == "Alerting::EvaluateJob" }).to be_empty
    end
  end

  describe "fix flip-flop (sezione systemd assente ~9/10 dei push)" do
    let(:no_systemd) do
      payload.deep_dup.tap do |p|
        p["recorded_at"] = "2026-07-02T10:01:00Z"
        p["data"].delete("systemd")
      end
    end

    it "preserva systemd_services/failed_services quando la sezione manca" do
      described_class.call(host:, payload:)
      expect(host.reload.failed_services).to eq(%w[backup.service])

      described_class.call(host: host.reload, payload: no_systemd)

      host.reload
      expect(host.failed_services).to eq(%w[backup.service])
      expect(host.systemd_services.length).to eq(2)
    end

    it "non ri-emette server_service_failed sul push senza sezione systemd" do
      described_class.call(host:, payload:)

      expect { described_class.call(host: host.reload, payload: no_systemd) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_service_failed"))
    end
  end

  describe "database" do
    # Push successivo (recorded_at diverso) con il blocco database modificato dal blocco passato.
    def push(host, at: "2026-07-02T10:01:00Z")
      raw = payload.deep_dup
      raw["recorded_at"] = at
      yield(raw)
      described_class.call(host: host.reload, payload: raw)
    end

    it "salva snapshot e ruolo sull'host" do
      described_class.call(host:, payload:)

      host.reload
      expect(host.db_role).to eq("primary")
      expect(host.database_snapshot["reachable"]).to be(true)
      expect(host.database_snapshot.dig("connections", "total")).to eq(42)
      expect(host.database_snapshot["top_tables"].first["name"]).to eq("public.events")
    end

    it "salva le hot columns sul campione" do
      described_class.call(host:, payload:)

      sample = Servers::Sample.last
      expect(sample.db_up).to be(true)
      expect(sample.db_connections).to eq(42)
      expect(sample.db_replication_lag_seconds).to eq(0.12)
      expect(sample.payload["database"]).to be_present
    end

    it "host senza database: nessuno snapshot, nessun ruolo, colonne nil" do
      no_db = payload.except("database")

      described_class.call(host:, payload: no_db)

      host.reload
      expect(host.database_snapshot).to eq({})
      expect(host.db_role).to be_nil
      sample = Servers::Sample.last
      expect(sample.db_up).to be_nil
      expect(sample.db_connections).to be_nil
    end

    it "blocco assente su un push successivo preserva l'ultimo snapshot noto (no flip-flop)" do
      described_class.call(host:, payload:)

      push(host) { |raw| raw.delete("database") }

      host.reload
      expect(host.db_role).to eq("primary")
      expect(host.database_snapshot.dig("connections", "total")).to eq(42)
    end

    describe "alert server_db_down" do
      it "avvisa alla transizione a non raggiungibile e NON ripete ai push successivi" do
        described_class.call(host:, payload:) # reachable true

        expect { push(host) { |raw| raw["database"]["reachable"] = false } }
          .to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "server_db_down", subject_id: host.id,
                               organization_id: host.organization_id, project_id: nil))

        expect { push(host, at: "2026-07-02T10:02:00Z") { |raw| raw["database"]["reachable"] = false } }
          .not_to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "server_db_down"))
      end

      it "primo push con database già giù (stato precedente sconosciuto) avvisa" do
        down = payload.deep_dup
        down["database"]["reachable"] = false

        expect { described_class.call(host:, payload: down) }
          .to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "server_db_down"))
      end

      it "database raggiungibile → nessun alert" do
        expect { described_class.call(host:, payload:) }
          .not_to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "server_db_down"))
      end

      it "blocco assente (host senza database) → nessun alert" do
        expect { described_class.call(host:, payload: payload.except("database")) }
          .not_to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "server_db_down"))
      end

      it "torna su e ricade → avvisa di nuovo" do
        described_class.call(host:, payload:)
        push(host) { |raw| raw["database"]["reachable"] = false }
        push(host, at: "2026-07-02T10:02:00Z") { |raw| raw["database"]["reachable"] = true }

        expect { push(host, at: "2026-07-02T10:03:00Z") { |raw| raw["database"]["reachable"] = false } }
          .to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "server_db_down"))
      end
    end

    describe "soglie database" do
      it "regola connessioni sotto il valore misurato → server_db_connections col valore" do
        create(:alerting_rule, organization: host.organization, event_type: :server_db_connections,
               name: "Connessioni alte", threshold: 40)

        expect { described_class.call(host:, payload:) }
          .to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "server_db_connections", value: 42.0))
      end

      it "regola connessioni sopra il valore misurato → nessun job (pre-check)" do
        create(:alerting_rule, organization: host.organization, event_type: :server_db_connections,
               name: "Connessioni alte", threshold: 90)

        expect { described_class.call(host:, payload:) }
          .not_to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "server_db_connections"))
      end

      it "regola percentuale slot usa max meno connessioni riservate" do
        create(:alerting_rule, organization: host.organization, event_type: :server_db_connection_usage,
               name: "Slot quasi pieni", threshold: 44)

        expect { described_class.call(host:, payload:) }
          .to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "server_db_connection_usage", value: 44.21))
      end

      it "regola lag sotto il valore misurato → server_replication_lag col valore" do
        create(:alerting_rule, organization: host.organization, event_type: :server_replication_lag,
               name: "Replica in ritardo", threshold: 0.1)

        expect { described_class.call(host:, payload:) }
          .to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "server_replication_lag", value: 0.12))
      end

      # Host senza database: le colonne db_* restano nil → il pre-check salta la regola (nessun job).
      %w[server_db_connections server_db_connection_usage server_replication_lag].each do |event_type|
        it "host senza database: la regola #{event_type} non genera nulla (valore nil)" do
          create(:alerting_rule, organization: host.organization, event_type: event_type,
                 name: "soglia #{event_type}", threshold: 0.01)

          expect { described_class.call(host:, payload: payload.except("database")) }
            .not_to have_enqueued_job(Alerting::EvaluateJob)
            .with(hash_including(event_type: event_type))
        end
      end
    end
  end

  # CYRA-248: un container che muore sparisce dal push (Docker non lista gli exited) e finora
  # svaniva senza avviso. Ora la sparizione fra due campioni genera server_container_down.
  describe "container down (CYRA-248)" do
    # Push successivo con il set container sostituito (o rimosso, motore non interrogabile).
    def push(host, containers, at: "2026-07-02T10:01:00Z", present: true)
      raw = payload.deep_dup
      raw["recorded_at"] = at
      if present
        raw["data"]["container"] = containers
      else
        raw["data"].delete("container")
      end
      described_class.call(host: host.reload, payload: raw)
    end

    # Nella fixture i container sono closeyourit-web (indice 0) e kamal-proxy (indice 1).
    let(:only_web) { [ payload["data"]["container"][0] ] }

    it "un container sparito (motore su) → server_container_down coi nomi caduti, un solo avviso" do
      described_class.call(host:, payload:) # set iniziale: closeyourit-web + kamal-proxy

      expect { push(host, only_web) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_down", subject_id: host.id,
                             organization_id: host.organization_id, project_id: nil))
        .once

      # CYRA-489 — l'outage porta anche l'istante d'inizio (serve all'avviso per dire «da quanto»).
      expect(host.reload.container_outage["names"]).to eq(%w[kamal-proxy])
      expect(host.container_outage["since"]).to be_present
    end

    it "un container ancora elencato ma stopped è caduto e non conta fra quelli attivi" do
      described_class.call(host:, payload:)
      stopped_proxy = payload["data"]["container"][1].merge("run" => false, "st" => "Exited (1)")

      expect { push(host, [ payload["data"]["container"][0], stopped_proxy ]) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_down"))

      # CYRA-489 — l'outage porta anche l'istante d'inizio (serve all'avviso per dire «da quanto»).
      expect(host.reload.container_outage["names"]).to eq(%w[kamal-proxy])
      expect(host.container_outage["since"]).to be_present
      expect(host.containers_count).to eq(1)
    end

    it "tutti i container spariti insieme (lista vuota) → un solo avviso: motore giù" do
      described_class.call(host:, payload:)

      expect { push(host, []) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_down"))
        .once

      expect(host.reload.container_outage).to eq("engine_down" => true)
    end

    it "sezione container assente (motore Docker non interrogabile) con container noti → motore giù" do
      described_class.call(host:, payload:)

      expect { push(host, nil, present: false) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_down"))

      expect(host.reload.container_outage).to eq("engine_down" => true)
    end

    it "non ripete l'avviso ai push successivi nello stesso stato (transizione)" do
      described_class.call(host:, payload:)
      push(host, [], at: "2026-07-02T10:01:00Z")

      expect { push(host, [], at: "2026-07-02T10:02:00Z") }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_down"))
    end

    it "conserva il nome nell'outage finché il container resta assente (no snapshot ripulito)" do
      described_class.call(host:, payload:)
      push(host, only_web, at: "2026-07-02T10:01:00Z")
      # CYRA-489 — l'outage porta anche l'istante d'inizio (serve all'avviso per dire «da quanto»).
      expect(host.reload.container_outage["names"]).to eq(%w[kamal-proxy])
      expect(host.container_outage["since"]).to be_present

      # kamal-proxy ANCORA assente: l'outage NON si azzera (altrimenti il job asincrono manderebbe un
      # avviso senza nome), e non parte un secondo avviso perché lo stato è invariato.
      expect { push(host, only_web, at: "2026-07-02T10:02:00Z") }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_down"))
      # CYRA-489 — l'outage porta anche l'istante d'inizio (serve all'avviso per dire «da quanto»).
      expect(host.reload.container_outage["names"]).to eq(%w[kamal-proxy])
      expect(host.container_outage["since"]).to be_present
    end

    it "primo push (nessun set precedente) non genera falsi avvisi di container" do
      expect { described_class.call(host:, payload:) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_down"))
    end

    it "torna sano quando i container riappaiono" do
      described_class.call(host:, payload:)
      push(host, only_web, at: "2026-07-02T10:01:00Z")
      # CYRA-489 — l'outage porta anche l'istante d'inizio (serve all'avviso per dire «da quanto»).
      expect(host.reload.container_outage["names"]).to eq(%w[kamal-proxy])
      expect(host.container_outage["since"]).to be_present

      push(host, payload["data"]["container"], at: "2026-07-02T10:02:00Z")
      expect(host.reload.container_outage).to eq({})
    end

    it "non aggiorna containers_count quando la sezione container è assente (info non disponibile)" do
      described_class.call(host:, payload:)
      expect(host.reload.containers_count).to eq(2)

      push(host, nil, present: false)
      expect(host.reload.containers_count).to eq(2) # preservato, non azzerato
    end

    it "aggiorna containers_count a 0 quando il motore risponde con lista vuota" do
      described_class.call(host:, payload:)

      push(host, [])
      expect(host.reload.containers_count).to eq(0)
    end

    it "host paused: rileva l'outage nello snapshot ma non avvisa" do
      described_class.call(host:, payload:)
      host.update!(status: :paused)

      expect { push(host, []) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_down"))
    end
  end

  # CYRA-512: su un host con idle-sleep (Sablier) lo stop è voluto, e i nomi che Kamal non riusa mai
  # restavano attesi per sempre — la lista dei caduti cresceva senza fine, un avviso a ogni variazione.
  describe "container fermati di proposito e memoria che scade (CYRA-512)" do
    def push(host, containers, at: "2026-07-02T10:01:00Z")
      raw = payload.deep_dup
      raw["recorded_at"] = at
      raw["data"]["container"] = containers
      described_class.call(host: host.reload, payload: raw)
    end

    let(:web) { payload["data"]["container"][0] }
    let(:proxy) { payload["data"]["container"][1] }

    it "un container gestito da idle-sleep che sparisce non è un guasto" do
      # kamal-proxy marcato idle-managed dall'agent: spegnerlo dopo l'inattività è il suo mestiere.
      sleeping = proxy.merge("im" => true)
      described_class.call(host:, payload: payload.deep_merge("data" => { "container" => [ web, sleeping ] }))

      expect { push(host, [ web ]) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_down"))
      expect(host.reload.container_outage).to eq({})
    end

    it "un container senza quel marchio che sparisce resta un guasto" do
      described_class.call(host:, payload:)

      expect { push(host, [ web ]) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_down"))
        .once
      # CYRA-489 — l'outage porta anche l'istante d'inizio (serve all'avviso per dire «da quanto»).
      expect(host.reload.container_outage["names"]).to eq(%w[kamal-proxy])
      expect(host.container_outage["since"]).to be_present
    end

    it "i nomi usa-e-getta di Kamal spariscono senza avviso" do
      replaced = web.merge("n" => "closeyourit-web_replaced_6b7441cfe551")
      one_off = web.merge("n" => "closeyourit-web-exec-latest-staging-cb9c24")
      described_class.call(host:, payload: payload.deep_merge("data" => { "container" => [ web, replaced, one_off ] }))

      expect { push(host, [ web ]) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_down"))
      expect(host.reload.container_outage).to eq({})
    end

    # CYRA-518 — sui runner di CI i database di servizio di ogni lavorazione nascono e muoiono a
    # ritmo continuo: 57 avvisi in 17 ore da due macchine. Devono tacere SENZA rendere sorda la
    # macchina: sullo stesso host un servizio vero che sparisce avvisa come prima.
    it "i database di una lavorazione di CI spariscono senza avviso, e un servizio vero avvisa lo stesso" do
      job_db = web.merge("n" => "4c39c1d1f4a04f0b8e5b8f5a0f3a1c7e_pgvectorpgvectorpg17_2b6a0f")
      described_class.call(host:, payload: payload.deep_merge("data" => { "container" => [ web, proxy, job_db ] }))

      expect { push(host, [ web, proxy ]) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_down"))
      expect(host.reload.container_outage).to eq({})

      expect { push(host, [ web ], at: "2026-07-02T10:02:00Z") }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_down"))
        .once
      expect(host.reload.container_outage["names"]).to eq(%w[kamal-proxy])
    end

    it "oltre la finestra di memoria il nome si dimentica, e il silenzio non diventa un falso rientro" do
      described_class.call(host:, payload:)
      push(host, [ web ], at: "2026-07-02T10:01:00Z")
      # CYRA-489 — l'outage porta anche l'istante d'inizio (serve all'avviso per dire «da quanto»).
      expect(host.reload.container_outage["names"]).to eq(%w[kamal-proxy])
      expect(host.container_outage["since"]).to be_present

      # kamal-proxy non si vede da oltre MEMORY_WINDOW: esce dagli attesi e l'outage si svuota. Nessun
      # avviso di rientro, perché nessuno è rientrato: chiude in silenzio.
      travel_to Time.zone.parse("2026-07-02T10:40:00Z")
      expect { push(host, [ web ], at: "2026-07-02T10:35:00Z") }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_up"))
      expect(host.reload.container_outage).to eq({})
    end

    it "il container che torna davvero annuncia il rientro" do
      described_class.call(host:, payload:)
      push(host, [ web ], at: "2026-07-02T10:01:00Z")
      # CYRA-489 — l'outage porta anche l'istante d'inizio (serve all'avviso per dire «da quanto»).
      expect(host.reload.container_outage["names"]).to eq(%w[kamal-proxy])
      expect(host.container_outage["since"]).to be_present

      expect { push(host, [ web, proxy ], at: "2026-07-02T10:02:00Z") }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_up", subject_id: host.id,
                             organization_id: host.organization_id, project_id: nil))
        .once
      expect(host.reload.container_outage).to eq({})
    end

    it "anche il motore che riparte annuncia il rientro" do
      described_class.call(host:, payload:)
      push(host, [], at: "2026-07-02T10:01:00Z")
      expect(host.reload.container_outage).to eq("engine_down" => true)

      expect { push(host, [ web, proxy ], at: "2026-07-02T10:02:00Z") }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_up"))
        .once
    end

    it "persiste il marchio sul campione, perché da fermo il container non si vede più" do
      sleeping = proxy.merge("im" => true)
      described_class.call(host:, payload: payload.deep_merge("data" => { "container" => [ web, sleeping ] }))

      samples = Servers::ContainerSample.where(host_id: host.id).index_by(&:name)
      expect(samples["kamal-proxy"].idle_managed).to be(true)
      expect(samples["closeyourit-web"].idle_managed).to be(false)
    end
  end

  # CYRA-774: pubblicare una versione nuova ferma il container di quella vecchia mentre il nuovo è
  # già in piedi. Quel nome non tornerà mai, e ogni rilascio produceva un «Contenitore caduto» per
  # ogni ruolo di ogni macchina: nel campione di quattro giorni una quarantina di avvisi falsi, in
  # mezzo ai quali un'applicazione davvero giù è passata inosservata per giorni.
  describe "rilascio che sostituisce i container (CYRA-774)" do
    def push(host, containers, at: "2026-07-02T10:01:00Z")
      raw = payload.deep_dup
      raw["recorded_at"] = at
      raw["data"]["container"] = containers
      described_class.call(host: host.reload, payload: raw)
    end

    # Kamal chiama il container `<servizio>-<ruolo>-<revisione>`: cambia solo la revisione.
    let(:old_release) { "7011b9d57b5f83845ea012073088b8c29b7b433a" }
    let(:new_release) { "c4d1e2f3a4b5968778695a4b3c2d1e0f9a8b7c6d" }
    let(:proxy) { payload["data"]["container"][1] }
    let(:template) { payload["data"]["container"][0] }
    let(:web_old) { template.merge("n" => "acme-web-#{old_release}", "id" => "aaaa11112222") }
    let(:web_new) { template.merge("n" => "acme-web-#{new_release}", "id" => "bbbb33334444") }
    let(:worker_old) { template.merge("n" => "acme-worker-#{old_release}", "id" => "cccc55556666") }

    it "la versione nuova che prende il posto della vecchia non è un guasto" do
      described_class.call(host:, payload: payload.deep_merge("data" => { "container" => [ web_old, proxy ] }))

      expect { push(host, [ web_new, proxy ]) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_down"))
      expect(host.reload.container_outage).to eq({})
    end

    it "il container che sparisce senza che nessuna versione riparta resta un guasto" do
      described_class.call(host:, payload: payload.deep_merge("data" => { "container" => [ web_old, proxy ] }))

      expect { push(host, [ proxy ]) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_down"))
        .once
      expect(host.reload.container_outage["names"]).to eq([ "acme-web-#{old_release}" ])
    end

    it "nello stesso push distingue il ruolo sostituito da quello caduto" do
      described_class.call(host:, payload: payload.deep_merge("data" => {
        "container" => [ web_old, worker_old, proxy ]
      }))

      expect { push(host, [ web_new, proxy ]) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_down"))
        .once
      expect(host.reload.container_outage["names"]).to eq([ "acme-worker-#{old_release}" ])
    end

    it "il container appena pubblicato che poi muore avvisa col suo nome, non con quello ritirato" do
      described_class.call(host:, payload: payload.deep_merge("data" => { "container" => [ web_old, proxy ] }))
      push(host, [ web_new, proxy ], at: "2026-07-02T10:01:00Z")
      expect(host.reload.container_outage).to eq({})

      expect { push(host, [ proxy ], at: "2026-07-02T10:02:00Z") }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_down"))
        .once
      expect(host.reload.container_outage["names"]).to eq([ "acme-web-#{new_release}" ])
    end

    # Un guasto si ripara anche pubblicando: il nome caduto non tornerà mai, ma il servizio è di
    # nuovo in piedi ed è esattamente quello che l'avviso prometteva. Cercare il nome esatto fra i
    # container in esecuzione lo mancava sempre, e l'avviso restava aperto senza chiusura.
    it "il guasto riparato pubblicando una versione nuova annuncia il rientro" do
      described_class.call(host:, payload: payload.deep_merge("data" => { "container" => [ web_old, proxy ] }))
      push(host, [ proxy ], at: "2026-07-02T10:01:00Z")
      expect(host.reload.container_outage["names"]).to eq([ "acme-web-#{old_release}" ])

      expect { push(host, [ web_new, proxy ], at: "2026-07-02T10:02:00Z") }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_up", subject_id: host.id,
                             organization_id: host.organization_id, project_id: nil))
        .once
      expect(host.reload.container_outage).to eq({})
    end

    it "il rilascio di un servizio non annuncia il rientro di un altro che è ancora giù" do
      described_class.call(host:, payload: payload.deep_merge("data" => { "container" => [ web_old, proxy ] }))
      push(host, [ web_old ], at: "2026-07-02T10:01:00Z")
      expect(host.reload.container_outage["names"]).to eq(%w[kamal-proxy])

      expect { push(host, [ web_new ], at: "2026-07-02T10:02:00Z") }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_up"))
      expect(host.reload.container_outage["names"]).to eq(%w[kamal-proxy])
    end

    # Il vecchio resta elencato da fermo finché Kamal non lo pota: fermo o sparito non cambia nulla,
    # ciò che conta è che una versione nuova dello stesso servizio stia girando.
    it "non avvisa nemmeno quando la versione vecchia resta elencata da ferma" do
      described_class.call(host:, payload: payload.deep_merge("data" => { "container" => [ web_old, proxy ] }))
      stopped = web_old.merge("run" => false, "st" => "Exited (0)")

      expect { push(host, [ stopped, web_new, proxy ]) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_down"))
      expect(host.reload.container_outage).to eq({})
    end
  end

  describe "soglie di capacità per volume e inode (CYRA-515)" do
    it "nomina il volume dati peggiore e genera l'evento sulla sua percentuale" do
      create(:alerting_rule, organization: host.organization, event_type: :server_data_volume_disk,
             name: "Volume quasi pieno", threshold: 40)

      expect { described_class.call(host:, payload:) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_data_volume_disk", value: 40.2))

      expect(host.reload.resource_pressure["data_volume_disk"])
        .to include("mountpoint" => "/mnt/data", "pct" => 40.2)
    end

    it "considera root ed extra filesystem e genera l'evento sull'inode peggiore" do
      create(:alerting_rule, organization: host.organization, event_type: :server_inode,
             name: "Inode quasi finiti", threshold: 70)

      expect { described_class.call(host:, payload:) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_inode", value: 75.0))

      expect(host.reload.resource_pressure["inode"])
        .to include("mountpoint" => "/mnt/data", "pct" => 75.0)
    end
  end

  describe "stato della replica nota (CYRA-515)" do
    let!(:standby) do
      create(:server_host, organization: host.organization, db_role: "standby", database_snapshot: {
        "system_identifier" => payload.dig("database", "system_identifier"),
        "role" => "standby",
        "reachable" => true,
        "replication" => { "streaming" => true }
      })
    end

    def replication_push(host, replicas:, at:)
      raw = payload.deep_dup
      raw["recorded_at"] = at
      raw["database"]["replication"]["replicas"] = replicas
      raw["database"]["replication"]["streaming"] = replicas.any?
      described_class.call(host: host.reload, payload: raw)
    end

    it "avvisa una sola volta quando una replica conosciuta scompare e annuncia il rientro" do
      described_class.call(host:, payload:)

      expect { replication_push(host, replicas: [], at: "2026-07-02T10:01:00Z") }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_replication_down"))
      expect(host.reload.replication_outage).to include("expected" => 1, "streaming" => 0)

      expect { replication_push(host, replicas: [], at: "2026-07-02T10:02:00Z") }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_replication_down"))

      replicas = [ { "client" => "10.0.0.10", "state" => "streaming" } ]
      expect { replication_push(host, replicas:, at: "2026-07-02T10:03:00Z") }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_replication_up"))
      expect(host.reload.replication_outage).to eq({})
    end

    it "non valuta come replica un database standalone senza peer noto" do
      standby.destroy!
      raw = payload.deep_dup
      raw["database"]["replication"]["replicas"] = []
      raw["database"]["replication"]["streaming"] = false

      expect { described_class.call(host:, payload: raw) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_replication_down"))
    end

    it "non annuncia un falso rientro se identità o peer del cluster diventano sconosciuti" do
      host.update!(replication_outage: { "role" => "primary", "expected" => 1, "streaming" => 0 })
      raw = payload.deep_dup
      raw["database"].delete("system_identifier")

      expect { described_class.call(host: host.reload, payload: raw) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_replication_up"))
      expect(host.reload.replication_outage).to include("expected" => 1, "streaming" => 0)

      standby.destroy!
      raw["recorded_at"] = "2026-07-02T10:01:00Z"
      raw["database"]["system_identifier"] = payload.dig("database", "system_identifier")

      expect { described_class.call(host: host.reload, payload: raw) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_replication_up"))
      expect(host.reload.replication_outage).to include("expected" => 1, "streaming" => 0)
    end
  end

  describe "restart loop container (CYRA-515)" do
    def restart_push(host, count:, at:, container_id: "abcdef123456", idle_managed: false)
      raw = payload.deep_dup
      raw["recorded_at"] = at
      raw["data"]["container"][0].merge!("id" => container_id, "rc" => count, "im" => idle_managed)
      described_class.call(host: host.reload, payload: raw)
    end

    it "avvisa dopo tre restart in dieci minuti, non ripete e annuncia quando la finestra torna stabile" do
      described_class.call(host:, payload:) # baseline rc=2 alle 10:00

      expect { restart_push(host, count: 5, at: "2026-07-02T10:04:00Z") }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_restart_loop"))
      expect(host.reload.container_restart_outage.dig("containers", 0))
        .to include("name" => "closeyourit-web", "restarts" => 3)

      expect { restart_push(host, count: 6, at: "2026-07-02T10:05:00Z") }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_restart_loop"))

      expect { restart_push(host, count: 6, at: "2026-07-02T10:11:00Z") }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_stable"))
      expect(host.reload.container_restart_outage).to eq({})
    end

    it "un container sostitutivo con lo stesso nome ma id nuovo non eredita il contatore" do
      described_class.call(host:, payload:)

      expect { restart_push(host, count: 50, at: "2026-07-02T10:04:00Z", container_id: "999999999999") }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_restart_loop"))
    end

    it "un container gestito da idle-sleep non genera restart loop" do
      described_class.call(host:, payload:)

      expect { restart_push(host, count: 10, at: "2026-07-02T10:04:00Z", idle_managed: true) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_container_restart_loop"))
    end
  end

  describe "journal" do
    it "inserisce le entries journald (stream err/crit)" do
      expect { described_class.call(host:, payload:) }
        .to change(Servers::Journal::Entry, :count).by(2)

      units = host.reload.journal_entries.pluck(:unit)
      expect(units).to contain_exactly("backup", "kernel")
    end

    it "è idempotente sui cursori: il retry non duplica le entries" do
      described_class.call(host:, payload:)

      expect { described_class.call(host: host.reload, payload:) }
        .to change(Servers::Journal::Entry, :count).by(0)
    end

    it "merge dello snapshot sull'host (keyed per unit failed)" do
      described_class.call(host:, payload:)

      snap = host.reload.journal_snapshots["backup.service"]
      expect(snap["lines"].size).to eq(3)
      expect(snap["captured_at"]).to be_present
    end

    it "rimuove lo snapshot quando la unit non è più failed (systemd presente)" do
      described_class.call(host:, payload:)
      expect(host.reload.journal_snapshots).to have_key("backup.service")

      recovered = payload.deep_dup
      recovered["recorded_at"] = "2026-07-02T10:01:00Z"
      recovered["data"]["systemd"][1]["s"] = 0 # backup.service torna active
      recovered["journal"].delete("snapshots")
      described_class.call(host: host.reload, payload: recovered)

      expect(host.reload.journal_snapshots).not_to have_key("backup.service")
    end

    it "preserva lo snapshot se la sezione systemd è assente (stato stale, non pruna)" do
      described_class.call(host:, payload:)

      stale = payload.deep_dup
      stale["recorded_at"] = "2026-07-02T10:01:00Z"
      stale["data"].delete("systemd")
      stale["journal"].delete("snapshots")
      described_class.call(host: host.reload, payload: stale)

      expect(host.reload.journal_snapshots).to have_key("backup.service")
    end

    it "una entry avvelenata non affonda il campione (journal fuori dalla transazione)" do
      allow(Servers::Journal::Entry).to receive(:insert_all).and_raise(ActiveRecord::StatementInvalid.new("bad"))

      expect { described_class.call(host:, payload:) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(Servers::Sample.count).to eq(1)
    end
  end
end
