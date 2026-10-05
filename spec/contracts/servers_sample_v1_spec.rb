# frozen_string_literal: true

require "rails_helper"
require "digest"
require "json_schemer"

# CYRA-724 — il lato server del contratto `servers-sample/v1`.
#
# Il campione che closeyourit-agent manda a `POST /api/v1/servers/samples` aveva finora un esempio
# solo, `spec/fixtures/servers/agent_payload.json`: vive qui dentro e nessun altro repository lo
# vede. Producer e consumer potevano quindi allontanarsi l'uno dall'altro senza che la differenza
# avesse un posto dove diventare rossa. Il bundle canonico (closeyourit-docs,
# `contracts/servers-sample/v1`) è ora vendorizzato qui accanto e pinnato dal `LOCK.json`: questa
# spec prova il server sugli STESSI esempi con cui l'agent prova se stesso, e il checksum-pin fa
# fallire il giro quando la copia si allontana dall'originale.
#
# Cosa il server rifiuta e cosa tollera è parte del contratto, non un dettaglio di implementazione:
# rifiuta soltanto il body non-oggetto o corrotto, il fingerprint assente e il payload oltre il MiB;
# tutto il resto lo coercia, lo tronca o lo ignora. Le fixture `invalid/` sono quindi in gran parte
# obblighi del PRODUCER, e qui si verifica la cosa che conta per noi: una loro violazione non rompe
# mai l'ingest e non scrive mai dati oltre i tetti dichiarati.
RSpec.describe "Servers sample contract v1", type: :request do
  include ActiveJob::TestHelper

  # let (non costanti top-level): CONTRACT_ROOT/CONTRACT di ingest_v1_spec sono globali e nella
  # suite completa sovrascriverebbero questi path.
  let(:contract_root) { Rails.root.join("contracts/servers-sample") }
  let(:contract) { contract_root.join("v1") }

  # Il recorded_at di ogni fixture è fisso (2026-09-01T10:00:00Z): congela il tempo poco dopo, o il
  # clamp anti-skew di Normalize sostituisce l'istante del contratto con quello del giro di test.
  let(:contract_now) { Time.zone.parse("2026-09-01T10:05:00Z") }

  def contract_json(relative)
    JSON.parse(contract.join(relative).read)
  end

  def fixture(name)
    contract_json("fixtures/#{name}.json")
  end

  def contract_schema
    @contract_schema ||= contract_json("schema.json")
  end

  def schema_errors(definition, document)
    contract_errors(contract_schema, definition, document)
  end

  def manifest_fixtures
    contract_json("manifest.json").fetch("fixtures")
  end

  # "fixtures/invalid/wrong_types.json" → "wrong_types"
  def invalid_fixture_names
    manifest_fixtures.reject { |item| item.fetch("valid") }
                     .map { |item| File.basename(item.fetch("path"), ".json") }
  end

  describe "lo snapshot vendorizzato" do
    it "corrisponde allo snapshot canonico bloccato e a tutti i checksum" do
      lock = JSON.parse(contract_root.join("LOCK.json").read)
      sums = contract.join("SHA256SUMS").read
      expect(Digest::SHA256.hexdigest(sums)).to eq(lock.fetch("sha256sums"))

      sums.each_line do |line|
        expected, relative = line.strip.split("  ./", 2)
        expect(Digest::SHA256.file(contract.join(relative)).hexdigest).to eq(expected), relative
      end
    end

    it "accetta e rifiuta ogni golden fixture contro il suo $def" do
      aggregate_failures do
        manifest_fixtures.each do |item|
          document = contract_json(item.fetch("path"))
          errors = schema_errors(item.fetch("definition"), document)

          if item.fetch("valid")
            expect(errors).to be_empty, "#{item['path']}: #{errors.map { |error| error['error'] }.join(', ')}"
          else
            expect(errors).not_to be_empty, "#{item['path']}: lo schema la accetta, ma il manifest la dice invalida"
          end
        end
      end
    end
  end

  describe "Servers::Ingest::Normalize sugli esempi validi" do
    before { travel_to contract_now }

    it "il campione minimo: nessun blocco opzionale, e le assenze restano assenze" do
      normalized = Servers::Ingest::Normalize.call(payload: fixture("valid/minimal"))

      expect(normalized.recorded_at).to eq(Time.zone.parse("2026-09-01T10:00:00Z"))
      expect(normalized.agent_version).to eq("0.9.3")
      expect(normalized.host_attrs).to eq(hostname: "ci-runner-1", reboot_required: false)
      # -1 dall'agent = "non lo so" (distro non-apt), non zero: la colonna resta vuota.
      expect(normalized.host_attrs).not_to have_key(:updates_available)
      expect(normalized.host_attrs).not_to have_key(:security_updates_available)
      # `data.container: null` = demone Docker non interrogabile, diverso da "nessun container".
      expect(normalized.container_present).to be(false)
      expect(normalized.containers).to eq([])
      expect(normalized.systemd_present).to be(false)
      expect(normalized.database_present).to be(false)
      expect(normalized.database_snapshot).to be_nil
      expect(normalized.sample_attrs).to include(cpu_pct: 3.2, mem_pct: 23.9, disk_pct: 32.55, load_1: 0.1)
    end

    describe "il campione completo" do
      subject(:normalized) { Servers::Ingest::Normalize.call(payload: fixture("valid/complete")) }

      it "traduce gli statici della macchina" do
        expect(normalized.host_attrs).to eq(
          hostname: "apps-staging", kernel: "6.8.0-59-generic", cores: 4, threads: 8,
          cpu_model: "AMD EPYC 9454P 48-Core Processor", os_name: "Ubuntu 24.04.2 LTS", arch: "amd64",
          memory_total_bytes: 8_127_683_584, reboot_required: true,
          updates_available: 12, security_updates_available: 3
        )
      end

      it "traduce le hot columns, comprese quelle derivate" do
        expect(normalized.sample_attrs).to include(
          cpu_pct: 12.34, mem_pct: 39.9, disk_pct: 54.68,
          gpu_pct: 7.5, gpu_watt: 61.2, temp_max: 48.5,
          load_1: 0.42, load_5: 0.38, load_15: 0.3,
          net_sent_bytes: 524_288, net_recv_bytes: 1_048_576,
          disk_read_bytes: 1_048_576, disk_write_bytes: 2_097_152,
          uptime_seconds: 864_000, services_total: 42, services_failed: 1
        )
      end

      it "nomina la risorsa sotto pressione, con la percentuale che il contratto implica" do
        # 100.5 GB su 250 = 40.2%; per gli inode vince il mount più pieno (75%) sulla root (40%).
        expect(normalized.resource_pressure).to eq(
          "data_volume_disk" => { "name" => "data", "mountpoint" => "/mnt/data", "pct" => 40.2 },
          "inode" => { "name" => "data", "mountpoint" => "/mnt/data", "pct" => 75.0 }
        )
        expect(normalized.sample_attrs).to include(data_volume_disk_pct: 40.2, inode_pct: 75.0)
      end

      it "traduce i container, con le unità e i default che il contratto dichiara" do
        containers = normalized.containers
        expect(normalized.container_present).to be(true)
        expect(containers.pluck(:name)).to eq(%w[closeyourit-web kamal-proxy clubbel-old-web])

        # `m` dei container è in MB, non in GB come le stats della macchina.
        expect(containers.first).to include(
          container_id: "abcdef123456", image: "registry.example.com/closeyourit:latest",
          status: "running", health: 2, idle_managed: false, running: true, restart_count: 2,
          oom_killed: false, cpu_pct: 2.5, mem_bytes: (512.25 * 1_048_576).round,
          net_sent_bytes: 10_240, net_recv_bytes: 20_480
        )
        expect(containers.first[:started_at]).to eq(Time.zone.parse("2026-09-01T09:00:00Z"))
        # `im` assente = false, `run` assente = true: un container che sparisce resta un guasto.
        expect(containers.second).to include(idle_managed: false, running: true, restart_count: 0, started_at: nil)
        # Il container fermo viaggia esplicito (`all=1`) e dichiara di essere gestito a spegnimento.
        expect(containers.third).to include(status: "exited", running: false, idle_managed: true)
      end

      it "traduce i vocabolari chiusi di systemd in stati leggibili" do
        expect(normalized.systemd_present).to be(true)
        expect(normalized.systemd_services).to contain_exactly(
          hash_including("name" => "ssh.service", "state" => "active", "sub" => "running"),
          hash_including("name" => "backup.service", "state" => "failed", "sub" => "failed")
        )
        expect(normalized.failed_service_names).to eq(%w[backup.service])
      end

      it "tiene lo stato SMART e lascia fuori gli attributes verbosi" do
        expect(normalized.smart_data.keys).to contain_exactly("nvme0", "sda")
        expect(normalized.smart_data.fetch("nvme0")).to eq(
          "model" => "SAMSUNG MZVL2512HCJQ-00B00", "serial" => "S64KNX2T216015", "firmware" => "GXA7601Q",
          "capacity_bytes" => 512_110_190_592, "status" => "PASSED", "device" => "/dev/nvme0",
          "type" => "nvme", "temp" => 41.0
        )
        expect(normalized.smart_data.fetch("sda")).to include("status" => "FAILED")
      end

      it "traduce il journal rispettando le unità del contratto (µs le entry, secondi gli snapshot)" do
        entries = normalized.journal_entries
        expect(entries.length).to eq(2)
        expect(entries.first).to include(
          cursor: "s=abc123;i=1a2b;b=boot0001;m=100200300;t=6551abc;x=deadbeef",
          priority: 3, unit: "backup", message: "Backup job failed: connection refused"
        )
        expect(entries.first[:occurred_at]).to eq(Time.zone.at(1_788_256_800))

        snapshot = normalized.journal_snapshots.fetch("backup.service")
        expect(snapshot.fetch("lines").length).to eq(3)
        expect(Time.zone.parse(snapshot.fetch("captured_at"))).to eq(Time.zone.at(1_788_256_800))
      end

      it "traduce il blocco database e ne deriva le hot columns" do
        expect(normalized.database_present).to be(true)
        expect(normalized.database_snapshot).to include(
          "engine" => "postgresql", "reachable" => true, "version" => "16.2",
          "role" => "primary", "system_identifier" => "7234567890123456789"
        )
        expect(normalized.database_snapshot.dig("replication", "lag_seconds")).to eq(0.12)
        # L'uso si misura sugli slot davvero disponibili: 42 su (100 - 5 riservati).
        expect(normalized.sample_attrs).to include(
          db_up: true, db_connections: 42, db_connection_usage_pct: 44.21, db_replication_lag_seconds: 0.12
        )
      end
    end

    it "il database rilevato ma non sondabile non porta con sé sotto-oggetti inventati" do
      normalized = Servers::Ingest::Normalize.call(payload: fixture("valid/database_unreachable"))

      expect(normalized.database_present).to be(true)
      expect(normalized.database_snapshot).to eq("engine" => "postgresql", "reachable" => false)
      expect(normalized.sample_attrs).to include(db_up: false, db_connections: nil, db_connection_usage_pct: nil)
    end

    # `limits.json` sta ESATTAMENTE sui tetti del server e sugli estremi dei vocabolari: se un tetto
    # qui si abbassa senza che il bundle canonico lo dica, il contratto e il server si separano.
    describe "il campione al limite" do
      subject(:normalized) { Servers::Ingest::Normalize.call(payload: fixture("valid/limits")) }

      it "tiene per intero le liste che stanno sui tetti" do
        expect(normalized.sample_attrs.dig(:payload, "processes").length).to eq(40)
        expect(normalized.journal_entries.length).to eq(500)
        expect(normalized.journal_snapshots.length).to eq(10)
        expect(normalized.journal_snapshots.values.map { |snap| snap.fetch("lines").length }).to all(eq(50))
        expect(normalized.database_snapshot.fetch("databases").length).to eq(50)
        expect(normalized.database_snapshot.fetch("top_tables").length).to eq(50)
        expect(normalized.database_snapshot.dig("replication", "replicas").length).to eq(20)
        expect(normalized.database_snapshot.dig("connections", "by_state").length).to eq(20)
      end

      it "non taglia i testi che stanno esattamente sul tetto" do
        expect(normalized.journal_entries.first[:message].length).to eq(1_024)
        expect(normalized.journal_snapshots.values.first.fetch("lines").first.length).to eq(512)
      end

      it "accetta gli estremi dei vocabolari chiusi" do
        expect(normalized.journal_entries.first[:priority]).to eq(7)
        expect(normalized.containers.first[:health]).to eq(3)
        expect(normalized.systemd_services.first).to include("state" => "reloading", "sub" => "unknown")
      end

      # CYRA-724 — il contratto dichiara i contatori `unsigned` senza tetto (il Go li emette da
      # uint32): la fixture porta il restart count a 4 294 967 295, che nella colonna a 32 bit non ci
      # sta. Senza clamp l'INSERT solleva e il push intero va perso per un numero implausibile.
      it "riporta nella colonna i contatori che il contratto lascia senza tetto" do
        expect(normalized.containers.first[:restart_count]).to eq(2_147_483_647)
      end
    end
  end

  # Le fixture `invalid/` descrivono payload che un producer deve rifiutare PRIMA di spedirli. Il
  # server ne rifiuta solo tre (fingerprint e forma del body); tutti gli altri li accetta e li
  # riporta dentro i tetti. Qui si verifica che quella tolleranza sia davvero tale: nessuna
  # eccezione, e nessun dato scritto fuori dai limiti dichiarati.
  describe "Servers::Ingest::Normalize sugli esempi che violano il contratto" do
    before { travel_to contract_now }

    # id della fixture → cosa il server ne fa. Ogni fixture invalid del manifest deve comparire in
    # una delle due liste: una violazione nuova senza comportamento dichiarato è un buco.
    let(:rejected_by_server) { %w[missing_fingerprint blank_fingerprint] }
    let(:tolerated_by_server) do
      %w[
        agent_version_with_v_prefix container_health_out_of_range data_without_container_key
        database_reachable_not_boolean database_role_unknown database_system_identifier_not_numeric
        database_top_tables_over_limit host_without_update_counters journal_priority_out_of_range
        journal_snapshot_lines_over_limit journal_snapshots_over_limit processes_over_limit
        systemd_state_out_of_range wrong_types
      ]
    end

    it "dichiara un comportamento per ogni violazione descritta dal contratto" do
      expect(rejected_by_server + tolerated_by_server).to match_array(invalid_fixture_names)
    end

    it "nessuna violazione tollerata fa saltare la normalizzazione" do
      aggregate_failures do
        tolerated_by_server.each do |name|
          expect { Servers::Ingest::Normalize.call(payload: fixture("invalid/#{name}")) }
            .not_to raise_error, name
        end
      end
    end

    it "tronca le liste oltre il tetto invece di scriverle intere" do
      processes = Servers::Ingest::Normalize.call(payload: fixture("invalid/processes_over_limit"))
                                            .sample_attrs.dig(:payload, "processes")
      expect(processes.length).to eq(40)

      snapshots = Servers::Ingest::Normalize.call(payload: fixture("invalid/journal_snapshots_over_limit"))
                                            .journal_snapshots
      expect(snapshots.length).to eq(10)

      lines = Servers::Ingest::Normalize.call(payload: fixture("invalid/journal_snapshot_lines_over_limit"))
                                        .journal_snapshots.fetch("u.service").fetch("lines")
      expect(lines.length).to eq(50)

      tables = Servers::Ingest::Normalize.call(payload: fixture("invalid/database_top_tables_over_limit"))
                                         .database_snapshot.fetch("top_tables")
      expect(tables.length).to eq(50)
    end

    it "riporta dentro l'intervallo i valori dei vocabolari chiusi" do
      priority = Servers::Ingest::Normalize.call(payload: fixture("invalid/journal_priority_out_of_range"))
                                           .journal_entries.first[:priority]
      expect(priority).to eq(7)

      health = Servers::Ingest::Normalize.call(payload: fixture("invalid/container_health_out_of_range"))
                                         .containers.first[:health]
      expect(health).to eq(3)

      # Stato systemd fuori vocabolario: ripiega su "inactive", mai su un nome inventato.
      service = Servers::Ingest::Normalize.call(payload: fixture("invalid/systemd_state_out_of_range"))
                                          .systemd_services.first
      expect(service).to include("state" => "inactive", "sub" => "running")
    end

    it "scarta i valori fuori vocabolario del database invece di fidarsene" do
      role = Servers::Ingest::Normalize.call(payload: fixture("invalid/database_role_unknown"))
                                       .database_snapshot
      expect(role).not_to have_key("role")

      identifier = Servers::Ingest::Normalize.call(payload: fixture("invalid/database_system_identifier_not_numeric"))
                                             .database_snapshot
      # Un "unknown" scritto uguale su macchine scollegate diventerebbe una falsa chiave di cluster.
      expect(identifier).not_to have_key("system_identifier")
    end

    # Il caso più delicato: un `reachable` malformato NON deve valere "database giù", o un payload
    # monco farebbe scattare l'allarme al posto di un guasto vero.
    it "un reachable non booleano resta sconosciuto, non diventa un guasto" do
      normalized = Servers::Ingest::Normalize.call(payload: fixture("invalid/database_reachable_not_boolean"))

      expect(normalized.database_present).to be(true)
      expect(normalized.database_snapshot).not_to have_key("reachable")
      expect(normalized.sample_attrs[:db_up]).to be_nil
    end

    it "i contatori di aggiornamento assenti non azzerano quello che sapevamo" do
      normalized = Servers::Ingest::Normalize.call(payload: fixture("invalid/host_without_update_counters"))

      expect(normalized.host_attrs).not_to have_key(:updates_available)
      expect(normalized.host_attrs).not_to have_key(:security_updates_available)
    end

    # `data.container` assente è indistinguibile, sul filo, da "motore Docker giù": il server sceglie
    # la lettura prudente e non conta zero container.
    it "la sezione container mancante vale motore non interrogabile, non zero container" do
      normalized = Servers::Ingest::Normalize.call(payload: fixture("invalid/data_without_container_key"))

      expect(normalized.container_present).to be(false)
      expect(normalized.containers).to eq([])
    end

    it "coercia i tipi sbagliati invece di rifiutare il campione" do
      normalized = Servers::Ingest::Normalize.call(payload: fixture("invalid/wrong_types"))

      # `cpu` come stringa resta un numero; `recorded_at` come intero non è un istante leggibile e
      # il campione prende l'ora di arrivo (stesso trattamento di un orologio impazzito).
      expect(normalized.sample_attrs[:cpu_pct]).to eq(12.34)
      expect(normalized.recorded_at).to eq(Time.current)
    end

    # `agent_version` col prefisso `v` non è un numero di versione confrontabile: il server non
    # rifiuta il push, ma non emette nemmeno la credenziale per-host, che dipende da quel confronto.
    it "una versione dell'agent fuori formato non ottiene la credenziale per-macchina" do
      organization = create(:organization)
      secret = Servers::EnrollmentTokens::Issue.call(organization:, name: "fleet").value[:secret]

      post "/api/v1/servers/samples", params: fixture("invalid/agent_version_with_v_prefix").to_json,
           headers: { "Authorization" => "Bearer #{secret}", "CONTENT_TYPE" => "application/json" }

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body.dig("data", "host_token")).to be_nil
    end
  end

  describe "Servers::Ingest::Record sugli esempi del contratto" do
    let(:organization) { create(:organization) }
    let(:host) { create(:server_host, organization:, fingerprint: fixture("valid/complete").fetch("fingerprint")) }

    before { travel_to contract_now }

    it "persiste il campione completo: host, campione e set container" do
      expect { Servers::Ingest::Record.call(host:, payload: fixture("valid/complete")) }
        .to change(Servers::Sample, :count).by(1)
        .and change(Servers::ContainerSample, :count).by(3)

      host.reload
      expect(host.status_up?).to be(true)
      expect(host.hostname).to eq("apps-staging")
      expect(host.agent_version).to eq("0.9.3")
      expect(host.last_seen_at).to eq(Time.zone.parse("2026-09-01T10:00:00Z"))
      expect(host.failed_services).to eq(%w[backup.service])
      expect(host.db_role).to eq("primary")
      expect(host.journal_entries.count).to eq(2)
      expect(host.journal_snapshots).to have_key("backup.service")
    end

    # Il contratto lo dichiara nella matrice HTTP: un retry con lo stesso istante è accettato e non
    # duplica niente (chiave [host, recorded_at]).
    it "il retry con lo stesso istante è un no-op, non un doppione" do
      Servers::Ingest::Record.call(host:, payload: fixture("valid/complete"))

      expect { Servers::Ingest::Record.call(host:, payload: fixture("valid/complete")) }
        .not_to change(Servers::Sample, :count)
    end

    it "persiste il campione al limite senza superare i tetti sul disco" do
      expect { Servers::Ingest::Record.call(host:, payload: fixture("valid/limits")) }
        .to change(Servers::Sample, :count).by(1)

      host.reload
      expect(host.journal_entries.count).to eq(500)
      expect(host.journal_snapshots.length).to eq(10)
      expect(host.database_snapshot.fetch("top_tables").length).to eq(50)
      expect(Servers::Sample.last.payload.fetch("processes").length).to eq(40)
      # Il campione del contratto arriva TUTTO, contatore fuori scala compreso: prima l'INSERT
      # sollevava e con lui moriva l'intero push.
      expect(Servers::ContainerSample.last.restart_count).to eq(2_147_483_647)
    end

    # Motore Docker non interrogabile: il conteggio noto si preserva, o la scheda della macchina
    # direbbe "zero container" ogni volta che Docker non risponde.
    it "un push senza sezione container non azzera i container conosciuti" do
      host.update!(containers_count: 4)

      Servers::Ingest::Record.call(host:, payload: fixture("valid/minimal"))

      expect(host.reload.containers_count).to eq(4)
    end
  end

  # Gli esiti HTTP e la matrice delle credenziali sono parte del bundle quanto lo schema: l'agent ci
  # costruisce sopra la propria disposizione (ritenta, si ferma, va in idle lungo). Un example per
  # caso, generato dal contratto: un caso nuovo nel bundle senza prova qui fa fallire il giro, che è
  # il difetto che questa spec esiste per rendere impossibile.
  describe "la matrice HTTP del contratto" do
    contract_dir = Rails.root.join("contracts/servers-sample/v1")
    auth_cases = JSON.parse(contract_dir.join("fixtures/http/auth-cases.json").read)
    # `network-error` non ha status: descrive il guasto di trasporto, dove il server non risponde
    # affatto: non c'è niente da provare da questa parte del filo.
    http_cases = JSON.parse(contract_dir.join("fixtures/http/cases.json").read).select { |item| item["status"] }

    let(:organization) { create(:organization) }
    let(:sample) { fixture("valid/complete") }
    let(:fingerprint) { sample.fetch("fingerprint") }
    let(:enrollment_secret) { Servers::EnrollmentTokens::Issue.call(organization:, name: "fleet").value[:secret] }
    let(:json_headers) { { "CONTENT_TYPE" => "application/json" } }

    let(:registered_host) { create(:server_host, organization:, fingerprint:) }

    let(:live_host_token) do
      secret = "cyi_h_#{SecureRandom.hex(8)}"
      create(:server_host_token, host: registered_host, token_digest: Digest::SHA256.hexdigest(secret))
      secret
    end

    let(:project_secret) do
      project = create(:project, organization:)
      environment = create(:environment, organization:).tap { |item| project.environments << item }
      Projects::Tokens::Issue.call(
        project:, name: "Contract", host: "bugs.example.com", environment:
      ).value[:secret]
    end

    def post_sample(body: nil, headers: {})
      post "/api/v1/servers/samples", params: (body || sample).to_json, headers: json_headers.merge(headers)
    end

    def bearer(secret)
      { "Authorization" => "Bearer #{secret}" }
    end

    def revoke_host_tokens
      registered_host.host_tokens.active.update_all(revoked_at: Time.current)
    end

    def perform_auth_case(id)
      case id
      when "enrollment-token"
        post_sample(headers: bearer(enrollment_secret))
      when "host-token"
        post_sample(headers: bearer(live_host_token))
      when "no-credential"
        post_sample
      when "enrollment-token-revoked"
        enrollment_secret # emissione prima della revoca: il let è lazy
        Servers::EnrollmentTokens::Revoke.call(token: Servers::EnrollmentToken.find_by!(organization:))
        post_sample(headers: bearer(enrollment_secret))
      when "project-bearer-rejected"
        post_sample(headers: bearer(project_secret))
      when "host-token-revoked"
        secret = live_host_token
        revoke_host_tokens
        post_sample(headers: bearer(secret))
      when "host-token-fingerprint-mismatch"
        post_sample(body: sample.merge("fingerprint" => "impronta-di-un-altra-macchina"),
                    headers: bearer(live_host_token))
      when "host-revoked"
        registered_host.update!(revoked_at: Time.current)
        post_sample(headers: bearer(enrollment_secret))
      else
        raise "caso di autenticazione del contratto senza prova: #{id}"
      end
    end

    def perform_http_case(id)
      case id
      when "accepted"
        # Macchina già arruolata che pusha con la propria credenziale: nessun token nuovo da emettere.
        post_sample(headers: bearer(live_host_token))
      when "accepted-host-token"
        post_sample(headers: bearer(enrollment_secret))
      when "unauthorized-no-credential"
        post_sample
      when "unauthorized-host-token-revoked"
        secret = live_host_token
        revoke_host_tokens
        post_sample(headers: bearer(secret))
      when "forbidden-host-revoked"
        registered_host.update!(revoked_at: Time.current)
        post_sample(headers: bearer(enrollment_secret))
      when "forbidden-fingerprint-mismatch"
        post_sample(body: sample.merge("fingerprint" => "impronta-di-un-altra-macchina"),
                    headers: bearer(live_host_token))
      when "payload-too-large"
        stub_const("Servers::Constants::MAX_PAYLOAD_BYTES", 10)
        post_sample(headers: bearer(enrollment_secret))
      when "unprocessable-missing-fingerprint"
        post_sample(body: fixture("invalid/missing_fingerprint"), headers: bearer(enrollment_secret))
      when "unprocessable-malformed"
        post "/api/v1/servers/samples", params: "[1,2]", headers: json_headers.merge(bearer(enrollment_secret))
      else
        raise "esito del contratto senza prova: #{id}"
      end
    end

    auth_cases.each do |item|
      it "#{item['id']} → #{item['status']}#{" #{item['code']}" if item['code']}" do
        perform_auth_case(item.fetch("id"))

        expect(response.status).to eq(item.fetch("status")), response.body
        expect(response.parsed_body.dig("error", "code")).to eq(item["code"]) if item["code"]
      end
    end

    it "le credenziali che il contratto nomina hanno davvero il prefisso dichiarato" do
      prefixes = auth_cases.filter_map { |item| [ item["credential"], item["prefix"] ] if item["prefix"] }.to_h

      expect(enrollment_secret).to start_with(prefixes.fetch("enrollment_token"))
      expect(live_host_token).to start_with(prefixes.fetch("host_token"))
      expect(project_secret).to start_with(prefixes.fetch("project_bearer"))
    end

    http_cases.each do |item|
      it "#{item['id']} → #{item['status']}#{" #{item['code']}" if item['code']}" do
        perform_http_case(item.fetch("id"))

        expect(response.status).to eq(item.fetch("status")), response.body
        expect(response.parsed_body.dig("error", "code")).to eq(item["code"]) if item["code"]

        case item.fetch("id")
        when "accepted"
          expect(schema_errors("sample_response", response.parsed_body)).to be_empty
          expect(response.parsed_body.dig("data", "host_token")).to be_nil
        when "accepted-host-token"
          # La credenziale per-macchina si emette UNA volta, al primo arruolamento di un agent ≥ 0.4.0.
          expect(schema_errors("sample_response", response.parsed_body)).to be_empty
          expect(response.parsed_body.dig("data", "host_token")).to start_with("cyi_h_")
        end
      end
    end

    it "il fingerprint blank è rifiutato come quello assente" do
      post_sample(body: fixture("invalid/blank_fingerprint"), headers: bearer(enrollment_secret))

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-SERVER-001")
    end

    it "il campione accettato accoda l'ingest" do
      expect { post_sample(headers: bearer(enrollment_secret)) }
        .to have_enqueued_job(Servers::IngestJob).once

      expect(response).to have_http_status(:accepted)
    end

    it "l'errore è nella busta del contratto e non accoda niente" do
      registered_host.update!(revoked_at: Time.current)

      expect { post_sample(headers: bearer(enrollment_secret)) }
        .not_to have_enqueued_job(Servers::IngestJob)

      expect(response).to have_http_status(:forbidden)
      expect(schema_errors("error_envelope", response.parsed_body)).to be_empty
      expect(response.parsed_body).to eq(fixture("valid/response_revoked"))
    end

    it "il body gzip dell'agent arriva al job decompresso" do
      expect do
        post "/api/v1/servers/samples", params: ActiveSupport::Gzip.compress(sample.to_json),
             headers: json_headers.merge(bearer(enrollment_secret)).merge("CONTENT_ENCODING" => "gzip")
      end.to have_enqueued_job(Servers::IngestJob)
        .with(hash_including(payload: hash_including("fingerprint" => fingerprint)))

      expect(response).to have_http_status(:accepted)
    end
  end
end
