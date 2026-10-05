# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::Ingest::Normalize do
  let(:payload) { JSON.parse(Rails.root.join("spec/fixtures/servers/agent_payload.json").read) }

  describe "sulla fixture condivisa (contratto wire dell'agent)" do
    subject(:normalized) { described_class.call(payload: payload) }

    # Il recorded_at della fixture è fisso: congela il tempo poco dopo, o il clamp anti-skew scatta.
    before { travel_to Time.zone.parse("2026-07-02T10:05:00Z") }

    it "estrae recorded_at e agent_version" do
      expect(normalized.recorded_at).to eq(Time.zone.parse("2026-07-02T10:00:00Z"))
      expect(normalized.agent_version).to eq("0.1.0")
    end

    it "traduce gli statici host in host_attrs" do
      expect(normalized.host_attrs).to eq(
        hostname: "apps-staging",
        kernel: "6.8.0-59-generic",
        cores: 4,
        threads: 8,
        cpu_model: "AMD EPYC 9454P 48-Core Processor",
        os_name: "Ubuntu 24.04.2 LTS",
        arch: "amd64",
        memory_total_bytes: 8_127_683_584,
        reboot_required: true,
        updates_available: 12,
        security_updates_available: 3
      )
    end

    it "updates_available -1 (sconosciuto dall'agent) → nil" do
      raw = payload.deep_dup
      raw["host"]["updates_available"] = -1
      normalized = described_class.call(payload: raw)

      expect(normalized.host_attrs).not_to have_key(:updates_available)
    end

    it "security_updates_available assente (agent < 0.8.0) → non impostato, non zero" do
      raw = payload.deep_dup
      raw["host"].delete("security_updates_available")
      normalized = described_class.call(payload: raw)

      expect(normalized.host_attrs).not_to have_key(:security_updates_available)
    end

    it "security_updates_available -1 (distro non-apt) → non impostato" do
      raw = payload.deep_dup
      raw["host"]["security_updates_available"] = -1
      normalized = described_class.call(payload: raw)

      expect(normalized.host_attrs).not_to have_key(:security_updates_available)
    end

    it "reboot_required assente (agent vecchio) → non impostato (default DB)" do
      raw = payload.deep_dup
      raw["host"].delete("reboot_required")
      normalized = described_class.call(payload: raw)

      expect(normalized.host_attrs).not_to have_key(:reboot_required)
    end

    it "traduce le hot columns del campione (chiavi compatte beszel → colonne)" do
      sample = normalized.sample_attrs
      expect(sample[:cpu_pct]).to eq(12.34)
      expect(sample[:mem_pct]).to eq(39.9)
      expect(sample[:disk_pct]).to eq(54.68)
      expect(sample[:gpu_pct]).to eq(7.5)
      expect(sample[:load_1]).to eq(0.42)
      expect(sample[:load_15]).to eq(0.3)
      expect(sample[:net_sent_bytes]).to eq(524_288)
      expect(sample[:net_recv_bytes]).to eq(1_048_576)
      expect(sample[:disk_read_bytes]).to eq(1_048_576)
      expect(sample[:disk_write_bytes]).to eq(2_097_152)
      expect(sample[:uptime_seconds]).to eq(864_000)
      expect(sample[:services_total]).to eq(42)
      expect(sample[:services_failed]).to eq(1)
      expect(sample[:db_connection_usage_pct]).to eq(44.21)
      expect(sample[:data_volume_disk_pct]).to eq(40.2)
      expect(sample[:inode_pct]).to eq(75.0)
    end

    it "temp_max = massimo dei sensori" do
      expect(normalized.sample_attrs[:temp_max]).to eq(48.5)
    end

    # CYRA-677 — top processi (chiave compatta `proc` dell'agent, CYAG-14): nel payload con nomi
    # espansi, agent vecchio (chiave assente) → nessuna chiave.
    it "normalizza i top processi nel payload" do
      processes = normalized.sample_attrs[:payload]["processes"]
      expect(processes.first).to eq(
        "pid" => 812, "name" => "postgres", "cpu_pct" => 41.5, "mem_bytes" => 812_000_000
      )
      expect(processes.length).to eq(3)
    end

    it "agent senza processi → chiave assente" do
      slim = payload.deep_dup
      slim["data"]["stats"].delete("proc")
      detail = described_class.call(payload: slim).sample_attrs[:payload]
      expect(detail).not_to have_key("processes")
    end

    it "mette il dettaglio nel payload (temps, extra_fs, mem/swap/disk assoluti)" do
      detail = normalized.sample_attrs[:payload]
      expect(detail["temps"]).to eq("k10temp_tctl" => 48.5, "nvme_composite" => 41.0)
      expect(detail["extra_fs"]).to have_key("sdb1")
      expect(detail["extra_fs"].dig("sdb1", "mp")).to eq("/mnt/data")
      expect(detail["mem"]).to eq("total_gb" => 7.57, "used_gb" => 3.02, "buff_cache_gb" => 2.51)
      expect(detail["swap"]).to eq("total_gb" => 4.0, "used_gb" => 0.25)
      expect(detail["disk"]).to eq(
        "total_gb" => 75.35, "used_gb" => 41.2,
        "inode_total" => 1_000_000, "inode_used" => 400_000, "inode_pct" => 40
      )
      expect(detail).not_to have_key("systemd")
    end

    it "traduce i container (mem MB → bytes, health int)" do
      web = normalized.containers.first
      expect(web[:name]).to eq("closeyourit-web")
      expect(web[:container_id]).to eq("abcdef123456")
      expect(web[:image]).to eq("registry.example.com/closeyourit:latest")
      expect(web[:status]).to eq("running")
      expect(web[:health]).to eq(2)
      expect(web[:running]).to be(true)
      expect(web[:restart_count]).to eq(2)
      expect(web[:started_at]).to eq(Time.zone.parse("2026-07-02T09:00:00Z"))
      expect(web[:oom_killed]).to be(false)
      expect(web[:cpu_pct]).to eq(2.5)
      expect(web[:mem_bytes]).to eq((512.25 * 1_048_576).round)
      expect(web[:net_sent_bytes]).to eq(10_240)
    end

    it "identifica le risorse peggiori per gli alert di capacità" do
      expect(normalized.resource_pressure).to eq(
        "data_volume_disk" => { "name" => "sdb1", "mountpoint" => "/mnt/data", "pct" => 40.2 },
        "inode" => { "name" => "sdb1", "mountpoint" => "/mnt/data", "pct" => 75.0 }
      )
    end

    it "traduce i servizi systemd in stato leggibile" do
      ssh = normalized.systemd_services.first
      expect(ssh).to include("name" => "ssh.service", "state" => "active", "sub" => "running")
      backup = normalized.systemd_services.last
      expect(backup).to include("name" => "backup.service", "state" => "failed", "sub" => "failed")
    end

    it "estrae i nomi dei servizi failed" do
      expect(normalized.failed_service_names).to eq(%w[backup.service])
    end

    it "traduce lo SMART per device" do
      expect(normalized.smart_data["nvme0"]).to include(
        "model" => "SAMSUNG MZVL2512HCJQ-00B00",
        "status" => "PASSED",
        "type" => "nvme",
        "temp" => 41.0,
        "capacity_bytes" => 512_110_190_592
      )
    end

    it "estrae le entries journald (cursor/priority/unit/message/occurred_at da µs)" do
      first = normalized.journal_entries.first
      expect(first).to eq(
        cursor: "s=abc123;i=1a2b;b=boot0001;m=100200300;t=6551abc;x=deadbeef",
        occurred_at: Time.zone.parse("2026-07-02T10:00:00Z"),
        priority: 3,
        unit: "backup",
        message: "Backup job failed: connection refused"
      )
      expect(normalized.journal_entries.last[:unit]).to eq("kernel")
      expect(normalized.journal_entries.last[:priority]).to eq(2)
    end

    it "estrae gli snapshot journalctl keyed per nome wire della unit" do
      snap = normalized.journal_snapshots["backup.service"]
      expect(snap["captured_at"]).to eq(Time.zone.at(1_782_986_400).iso8601)
      expect(snap["lines"].size).to eq(3)
      expect(snap["lines"].last).to include("status=1/FAILURE")
    end

    it "la sezione systemd è presente nella fixture" do
      expect(normalized.systemd_present).to be(true)
    end

    it "la sezione container è presente nella fixture" do
      expect(normalized.container_present).to be(true)
    end

    it "traduce il blocco database in snapshot leggibile (contratto wire)" do
      expect(normalized.database_present).to be(true)
      expect(normalized.database_snapshot).to eq(
        "engine" => "postgresql",
        "reachable" => true,
        "version" => "16.2",
        "role" => "primary",
        "system_identifier" => "7234567890123456789",
        "connections" => {
          "total" => 42, "max" => 100, "reserved" => 5,
          "by_state" => { "active" => 5, "idle" => 30, "idle_in_transaction" => 7 }
        },
        "replication" => {
          "streaming" => true, "lag_seconds" => 0.12,
          "replicas" => [ { "client" => "10.0.0.10", "state" => "streaming" } ]
        },
        "databases" => [ { "name" => "app_production", "size_bytes" => 123_456_789 } ],
        "top_tables" => [ { "database" => "app_production", "name" => "public.events", "size_bytes" => 98_765_432 } ]
      )
    end

    it "estrae le hot columns del database sul campione" do
      sample = normalized.sample_attrs
      expect(sample[:db_up]).to be(true)
      expect(sample[:db_connections]).to eq(42)
      expect(sample[:db_connection_usage_pct]).to eq(44.21)
      expect(sample[:db_replication_lag_seconds]).to eq(0.12)
    end

    it "mette il dettaglio database nel payload del campione" do
      expect(normalized.sample_attrs[:payload]["database"]).to eq(normalized.database_snapshot)
    end
  end

  describe "confini e input degeneri" do
    it "payload vuoto/non-hash → default sicuri e recorded_at = now" do
      travel_to Time.zone.local(2026, 7, 2, 12, 0, 0) do
        normalized = described_class.call(payload: nil)

        expect(normalized.recorded_at).to eq(Time.current)
        expect(normalized.host_attrs).to eq({})
        expect(normalized.sample_attrs[:cpu_pct]).to eq(0.0)
        expect(normalized.containers).to eq([])
        expect(normalized.systemd_services).to eq([])
        expect(normalized.smart_data).to eq({})
        expect(normalized.failed_service_names).to eq([])
      end
    end

    it "recorded_at oltre lo skew futuro → clampato a now" do
      travel_to Time.zone.local(2026, 7, 2, 12, 0, 0) do
        normalized = described_class.call(payload: { "recorded_at" => 2.hours.from_now.iso8601 })

        expect(normalized.recorded_at).to eq(Time.current)
      end
    end

    it "recorded_at non parsabile → now" do
      travel_to Time.zone.local(2026, 7, 2, 12, 0, 0) do
        expect(described_class.call(payload: { "recorded_at" => "boom" }).recorded_at).to eq(Time.current)
      end
    end

    it "senza sensori usa la dashboard temp (info.dt)" do
      normalized = described_class.call(payload: { "data" => { "info" => { "dt" => 51.5 } } })

      expect(normalized.sample_attrs[:temp_max]).to eq(51.5)
    end

    it "container senza name e item non-hash vengono scartati" do
      normalized = described_class.call(payload: { "data" => { "container" => [ { "c" => 1 }, "junk", { "n" => "ok" } ] } })

      expect(normalized.containers.map { |c| c[:name] }).to eq(%w[ok])
    end

    it "payload container di un agent precedente resta running e senza contatore" do
      normalized = described_class.call(payload: { "data" => { "container" => [ { "n" => "legacy" } ] } })

      expect(normalized.containers.first).to include(running: true, restart_count: 0, oom_killed: false)
    end

    it "stato systemd fuori vocabolario → inactive/unknown" do
      normalized = described_class.call(payload: { "data" => { "systemd" => [ { "n" => "x", "s" => 99, "ss" => 42 } ] } })

      expect(normalized.systemd_services.first).to include("state" => "inactive", "sub" => "unknown")
    end

    it "proc: voci non-hash e senza nome scartate, le buone restano" do
      normalized = described_class.call(payload: { "data" => { "stats" => {
        "proc" => [ "junk", { "p" => 1, "n" => "", "c" => 1, "m" => 2 },
                    { "p" => 2, "n" => "puma", "c" => 1.5, "m" => 3 } ]
      } } })

      expect(normalized.sample_attrs[:payload]["processes"].map { |p| p["name"] }).to eq(%w[puma])
    end

    it "proc: lista di soli scarti → nessuna chiave processes" do
      normalized = described_class.call(payload: { "data" => { "stats" => { "proc" => [ { "n" => "" } ] } } })

      expect(normalized.sample_attrs[:payload]).not_to have_key("processes")
    end

    it "pressione dischi: volumi senza totale, con totale zero o senza usato non concorrono" do
      normalized = described_class.call(payload: { "data" => { "stats" => { "efs" => {
        "no-total" => { "du" => 1 }, "zero" => { "d" => 0, "du" => 1 }, "no-used" => { "d" => 10 },
        "buono" => { "d" => 10, "du" => 5 }, "junk" => "x"
      } } } })

      expect(normalized.resource_pressure.dig("data_volume_disk", "name")).to eq("buono")
      expect(normalized.resource_pressure.dig("data_volume_disk", "pct")).to eq(50.0)
    end

    it "pressione dischi: soli candidati degeneri → nessuna pressione, non uno zero" do
      normalized = described_class.call(payload: { "data" => { "stats" => { "efs" => {
        "no-total" => { "du" => 1 }, "zero" => { "d" => 0, "du" => 1 }, "no-used" => { "d" => 10 }
      } } } })

      expect(normalized.resource_pressure["data_volume_disk"]).to be_nil
    end

    it "pressione inode: il root (stats.ip) concorre coi volumi extra" do
      normalized = described_class.call(payload: { "data" => { "stats" => {
        "ip" => 91.0, "efs" => { "dati" => { "ip" => 40 } }
      } } })

      expect(normalized.resource_pressure.dig("inode", "name")).to eq("root")
    end

    it "systemd: voci non-hash e senza nome scartate" do
      normalized = described_class.call(payload: { "data" => { "systemd" => [ "junk", { "s" => 1 }, { "n" => "cron" } ] } })

      expect(normalized.systemd_services.map { |s| s["name"] }).to eq(%w[cron])
    end

    it "smart: dispositivi non-hash scartati, campi vuoti compattati" do
      normalized = described_class.call(payload: { "smart" => {
        "junk" => "x", "nvme0" => { "mn" => "", "s" => "PASSED" }
      } })

      expect(normalized.smart_data.keys).to eq(%w[nvme0])
      expect(normalized.smart_data["nvme0"]).to eq("status" => "PASSED")
    end

    it "database: replicas non-hash o vuote scartate" do
      normalized = described_class.call(payload: { "database" => {
        "engine" => "postgres", "reachable" => true,
        "replication" => { "replicas" => [ "junk", {}, { "client" => "standby1", "state" => "streaming" } ] }
      } })

      expect(normalized.database_snapshot.dig("replication", "replicas"))
        .to eq([ { "client" => "standby1", "state" => "streaming" } ])
    end

    describe "journal" do
      it "payload senza chiave journal (agent vecchio) → entries/snapshots vuoti (no-op)" do
        normalized = described_class.call(payload: { "data" => {} })

        expect(normalized.journal_entries).to eq([])
        expect(normalized.journal_snapshots).to eq({})
      end

      it "systemd_present distingue sezione assente (nil) da presente" do
        expect(described_class.call(payload: {}).systemd_present).to be(false)
        expect(described_class.call(payload: { "data" => { "systemd" => [] } }).systemd_present).to be(true)
      end

      # Come systemd: il motore container giù fa viaggiare `data.container` come null (agent: nil senza
      # omitempty), indistinguibile da "presente ma vuota". Il flag separa i due casi → Record non
      # svuota il conteggio quando l'informazione manca, e valuta la sparizione solo quando c'è.
      it "container_present distingue sezione assente (nil) da presente-ma-vuota" do
        expect(described_class.call(payload: {}).container_present).to be(false)
        expect(described_class.call(payload: { "data" => { "container" => [] } }).container_present).to be(true)
      end

      it "scarta entry non-hash e snapshot con unit vuota o corpo non-hash" do
        payload = { "journal" => {
          "entries" => [ "junk", { "c" => "cur", "t" => 1, "p" => 3, "m" => "ok" } ],
          "snapshots" => { "" => { "lines" => [ "x" ] }, "bad.service" => "junk",
                           "ok.service" => { "t" => 1_782_986_400, "lines" => [ "riga" ] } }
        } }

        normalized = described_class.call(payload: payload)
        expect(normalized.journal_entries.map { |e| e[:cursor] }).to eq(%w[cur])
        expect(normalized.journal_snapshots.keys).to eq(%w[ok.service])
      end

      it "timestamp µs non numerico → now; captured_at non numerico → nil" do
        travel_to Time.zone.local(2026, 7, 2, 12, 0, 0) do
          payload = { "journal" => {
            "entries" => [ { "c" => "cur", "t" => "boom", "p" => 3, "m" => "ok" } ],
            "snapshots" => { "s.service" => { "t" => "boom", "lines" => [ "riga" ] } }
          } }

          normalized = described_class.call(payload: payload)
          expect(normalized.journal_entries.first[:occurred_at]).to eq(Time.current)
          expect(normalized.journal_snapshots.dig("s.service", "captured_at")).to be_nil
        end
      end

      it "timestamp µs nel futuro oltre lo skew → clampato a now" do
        travel_to Time.zone.local(2026, 7, 2, 12, 0, 0) do
          micros = (3.hours.from_now.to_f * 1_000_000).to_i
          payload = { "journal" => { "entries" => [ { "c" => "cur", "t" => micros, "p" => 3, "m" => "ok" } ] } }

          expect(described_class.call(payload: payload).journal_entries.first[:occurred_at]).to eq(Time.current)
        end
      end

      it "scarta entry senza cursore o con message vuoto" do
        payload = { "journal" => { "entries" => [
          { "c" => "", "t" => 1, "p" => 3, "m" => "no cursor" },
          { "c" => "cur1", "t" => 1, "p" => 3, "m" => "  " },
          { "c" => "cur2", "t" => 1, "p" => 3, "m" => "ok" }
        ] } }

        entries = described_class.call(payload: payload).journal_entries
        expect(entries.map { |e| e[:cursor] }).to eq(%w[cur2])
      end

      it "rimuove i null-byte dal message (Postgres li rifiuta)" do
        payload = { "journal" => { "entries" => [ { "c" => "cur", "t" => 1, "p" => 3, "m" => "a#{0.chr}b" } ] } }

        expect(described_class.call(payload: payload).journal_entries.first[:message]).to eq("ab")
      end

      it "scruba i byte non-UTF8 nel message" do
        bad = (+"ok").force_encoding("ASCII-8BIT") << 255.chr
        payload = { "journal" => { "entries" => [ { "c" => "cur", "t" => 1, "p" => 3, "m" => bad } ] } }

        message = described_class.call(payload: payload).journal_entries.first[:message]
        expect(message).to be_valid_encoding
        expect(message).to start_with("ok")
      end

      it "clampa la priority nel range 0..7" do
        payload = { "journal" => { "entries" => [
          { "c" => "a", "t" => 1, "p" => 99, "m" => "x" },
          { "c" => "b", "t" => 1, "p" => -5, "m" => "y" }
        ] } }

        priorities = described_class.call(payload: payload).journal_entries.map { |e| e[:priority] }
        expect(priorities).to eq([ 7, 0 ])
      end

      it "clampa occurred_at oltre lo skew futuro a now (µs)" do
        travel_to Time.zone.local(2026, 7, 2, 12, 0, 0) do
          future_micros = (2.hours.from_now.to_r * 1_000_000).to_i
          payload = { "journal" => { "entries" => [ { "c" => "a", "t" => future_micros, "p" => 3, "m" => "x" } ] } }

          expect(described_class.call(payload: payload).journal_entries.first[:occurred_at]).to eq(Time.current)
        end
      end

      it "cappa le entries a 500 per push" do
        entries = Array.new(600) { |i| { "c" => "cur#{i}", "t" => 1, "p" => 3, "m" => "m#{i}" } }

        result = described_class.call(payload: { "journal" => { "entries" => entries } }).journal_entries
        expect(result.size).to eq(500)
      end

      it "cappa unit e righe degli snapshot" do
        snaps = (0..14).to_h { |i| [ "u#{i}.service", { "t" => 1, "lines" => Array.new(80) { |n| "line#{n}" } } ] }

        result = described_class.call(payload: { "journal" => { "snapshots" => snaps } }).journal_snapshots
        expect(result.size).to eq(10)
        expect(result.values.first["lines"].size).to eq(50)
      end

      # CYRA-735 — i log di sistema della macchina sono la sorgente di testo più libera del prodotto e
      # fino a ora l'unica del tutto priva di redazione: ci finiscono dentro indirizzi con il token
      # nella query e righe di configurazione con la password. Ora vale la stessa policy dei canali
      # errori e log.
      describe "rimozione dei dati personali dal testo (CYRA-735)" do
        it "redige il valore sensibile in una riga di journald e lascia leggibile la frase" do
          payload = { "journal" => { "entries" => [
            { "c" => "cur", "t" => 1, "p" => 3, "m" => "curl https://x.test/a?token=SECRET fallita" }
          ] } }

          message = described_class.call(payload: payload).journal_entries.first[:message]
          expect(message).to eq("curl https://x.test/a?token=[FILTERED] fallita")
        end

        it "redige anche le righe degli snapshot delle unit in errore" do
          snaps = { "backup.service" => { "t" => 1, "lines" => [ "password=hunter2", "exit status 1" ] } }

          lines = described_class.call(payload: { "journal" => { "snapshots" => snaps } })
                                 .journal_snapshots["backup.service"]["lines"]
          expect(lines).to eq([ "password=[FILTERED]", "exit status 1" ])
        end

        it "non tocca il resto del testo: le righe di sistema restano diagnosticabili" do
          payload = { "journal" => { "entries" => [
            { "c" => "cur", "t" => 1, "p" => 3, "m" => "Backup job failed: connection refused" }
          ] } }

          expect(described_class.call(payload: payload).journal_entries.first[:message])
            .to eq("Backup job failed: connection refused")
        end

        it "redige un'intestazione di autenticazione e un indirizzo email in una riga di sistema" do
          payload = { "journal" => { "entries" => [
            { "c" => "a", "t" => 1, "p" => 3, "m" => "Authorization: Bearer SECRET" },
            { "c" => "b", "t" => 1, "p" => 3, "m" => "invio a mario.rossi@example.com fallito" }
          ] } }

          expect(described_class.call(payload: payload).journal_entries.map { |e| e[:message] })
            .to eq([ "Authorization: [FILTERED]", "invio a [FILTERED] fallito" ])
        end

        it "NON tocca il nome di un servizio a istanze, che ha la forma di un indirizzo email" do
          payload = { "journal" => { "entries" => [
            { "c" => "a", "t" => 1, "p" => 3, "m" => "getty@tty1.service entered failed state" }
          ] } }

          expect(described_class.call(payload: payload).journal_entries.first[:message])
            .to eq("getty@tty1.service entered failed state")
        end

        it "il tetto della riga vale DOPO la redazione (il segnaposto è più lungo del valore)" do
          lunga = "#{"a" * 1_020} token=x"
          payload = { "journal" => { "entries" => [ { "c" => "cur", "t" => 1, "p" => 3, "m" => lunga } ] } }

          message = described_class.call(payload: payload).journal_entries.first[:message]
          expect(message.length).to be <= described_class::JOURNAL_MESSAGE_MAX
        end

        it "redige anche quando la riga porta byte non validi (prima si ripara, poi si redige)" do
          sporca = (+"token=SECRET ").force_encoding("ASCII-8BIT") << 255.chr
          payload = { "journal" => { "entries" => [ { "c" => "cur", "t" => 1, "p" => 3, "m" => sporca } ] } }

          message = described_class.call(payload: payload).journal_entries.first[:message]
          expect(message).to be_valid_encoding
          expect(message).to start_with("token=[FILTERED]")
        end
      end
    end

    describe "database" do
      def normalize(block) = described_class.call(payload: { "database" => block })

      it "blocco assente (host senza database) → nessuno snapshot e colonne db_* nil" do
        normalized = described_class.call(payload: { "data" => {} })

        expect(normalized.database_present).to be(false)
        expect(normalized.database_snapshot).to be_nil
        expect(normalized.sample_attrs[:db_up]).to be_nil
        expect(normalized.sample_attrs[:db_connections]).to be_nil
        expect(normalized.sample_attrs[:db_replication_lag_seconds]).to be_nil
        expect(normalized.sample_attrs[:payload]).not_to have_key("database")
      end

      it "blocco non-hash → trattato come assente" do
        expect(described_class.call(payload: { "database" => "postgres" }).database_present).to be(false)
      end

      it "reachable false (DB rilevato ma non sondabile) → presente coi soli campi arrivati" do
        normalized = normalize("engine" => "postgresql", "reachable" => false, "role" => "standby")

        expect(normalized.database_present).to be(true)
        expect(normalized.database_snapshot)
          .to eq("engine" => "postgresql", "reachable" => false, "role" => "standby")
        expect(normalized.sample_attrs[:db_up]).to be(false)
        expect(normalized.sample_attrs[:db_connections]).to be_nil
      end

      it "reachable assente o non booleano → sconosciuto (nil), MAI false" do
        expect(normalize("engine" => "postgresql").database_snapshot).not_to have_key("reachable")
        expect(normalize("reachable" => "yes").database_snapshot).not_to have_key("reachable")
        expect(normalize("reachable" => "yes").sample_attrs[:db_up]).to be_nil
      end

      it "role fuori vocabolario → nil (il badge non inventa etichette)" do
        expect(normalize("role" => "witness").database_snapshot).not_to have_key("role")
      end

      it "system_identifier assente (agent < 0.6.0) → chiave assente, non nil" do
        expect(normalize("engine" => "postgresql").database_snapshot).not_to have_key("system_identifier")
      end

      it "system_identifier valido: stringa di sole cifre, ripulita agli estremi" do
        expect(normalize("system_identifier" => " 7234567890123456789 ").database_snapshot["system_identifier"])
          .to eq("7234567890123456789")
        expect(normalize("system_identifier" => 7_234_567_890_123_456_789).database_snapshot["system_identifier"])
          .to eq("7234567890123456789")
      end

      # È l'identificativo numerico di un cluster: qualunque altra cosa non lo è. Il campo pilota
      # l'accorpamento delle copie, quindi un valore sentinella tipo "unknown" — identico su macchine
      # scollegate fra loro — le unirebbe per sbaglio. Fuori formato = assente, si torna a dedurre.
      it "system_identifier fuori formato: assente (mai chiave di cluster)" do
        [ "unknown", "abc", "", "  ", "-1", "1.5", "9" * 21 ].each do |raw|
          expect(normalize("system_identifier" => raw).database_snapshot)
            .not_to(have_key("system_identifier"), "atteso scartato: #{raw.inspect}")
        end
      end

      it "lag_seconds assente → nil (sconosciuto, non zero)" do
        normalized = normalize("replication" => { "streaming" => true })

        expect(normalized.database_snapshot["replication"]).to eq("streaming" => true)
        expect(normalized.sample_attrs[:db_replication_lag_seconds]).to be_nil
      end

      it "scarta database/tabelle senza nome e gli item non-hash" do
        normalized = normalize(
          "databases" => [ { "size_bytes" => 1 }, "junk", { "name" => "ok", "size_bytes" => 2 } ],
          "top_tables" => [ { "database" => "d", "size_bytes" => 3 }, { "name" => "public.t" } ]
        )

        expect(normalized.database_snapshot["databases"]).to eq([ { "name" => "ok", "size_bytes" => 2 } ])
        expect(normalized.database_snapshot["top_tables"]).to eq([ { "name" => "public.t" } ])
      end

      it "liste vuote non finiscono nello snapshot" do
        normalized = normalize("databases" => [], "top_tables" => [], "connections" => {})

        expect(normalized.database_snapshot).to eq({})
      end

      it "cappa databases, top_tables, repliche e stati delle connessioni" do
        normalized = normalize(
          "databases" => Array.new(80) { |i| { "name" => "db#{i}", "size_bytes" => i } },
          "top_tables" => Array.new(80) { |i| { "name" => "t#{i}", "size_bytes" => i } },
          "connections" => { "by_state" => (0..30).to_h { |i| [ "state#{i}", i ] } },
          "replication" => { "replicas" => Array.new(40) { |i| { "client" => "10.0.0.#{i}" } } }
        )

        snapshot = normalized.database_snapshot
        expect(snapshot["databases"].size).to eq(50)
        expect(snapshot["top_tables"].size).to eq(50)
        expect(snapshot["connections"]["by_state"].size).to eq(20)
        expect(snapshot["replication"]["replicas"].size).to eq(20)
      end

      it "scruba i null-byte dai nomi (Postgres li rifiuta nel jsonb)" do
        normalized = normalize("databases" => [ { "name" => "app#{0.chr}prod", "size_bytes" => 1 } ])

        expect(normalized.database_snapshot["databases"].first["name"]).to eq("appprod")
      end
    end
  end

  describe "scheda grafica (CYRA-703)" do
    # L'agent manda le GPU in stats["g"]: { "0" => { "n" => nome, "u" => uso%, "p" => watt } }.
    def payload_con_gpu(gpus)
      { "data" => { "stats" => { "cpu" => 10.0, "g" => gpus }, "info" => { "cpu" => 10.0, "u" => 3600 } } }
    end

    it "registra l'uso a zero come zero, non come dato mancante" do
      campione = described_class.call(payload: payload_con_gpu("0" => { "n" => "GB10", "u" => 0, "p" => 11.2 })).sample_attrs

      expect(campione[:gpu_pct]).to eq(0)
    end

    it "registra i watt assorbiti dalla scheda" do
      campione = described_class.call(payload: payload_con_gpu("0" => { "n" => "GB10", "u" => 0, "p" => 11.2 })).sample_attrs

      expect(campione[:gpu_watt]).to eq(11.2)
    end

    it "con più schede prende l'uso della più carica e la somma dei watt" do
      campione = described_class.call(payload: payload_con_gpu(
        "0" => { "n" => "A", "u" => 12.0, "p" => 100.0 },
        "1" => { "n" => "B", "u" => 87.5, "p" => 150.0 }
      )).sample_attrs

      expect(campione[:gpu_pct]).to eq(87.5)
      expect(campione[:gpu_watt]).to eq(250.0)
    end

    it "senza scheda grafica lascia le due colonne vuote" do
      campione = described_class.call(payload: payload_con_gpu(nil)).sample_attrs

      expect(campione[:gpu_pct]).to be_nil
      expect(campione[:gpu_watt]).to be_nil
    end
  end
end
