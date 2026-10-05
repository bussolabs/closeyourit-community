# frozen_string_literal: true

module Servers
  module Ingest
    # Persiste un push dell'agent: aggiorna l'host (snapshot + statici + stato systemd/SMART +
    # last_seen), inserisce il campione (idempotente su [host, recorded_at]) e i campioni container.
    # Dopo il commit valuta gli alert: recovery down→up, nuovi servizi failed, SMART passed→failed,
    # soglie cpu/mem/disk/temp. Host paused: registra i dati ma non tocca lo status né avvisa.
    class Record < ApplicationService
      THRESHOLD_EVENTS = {
        "server_cpu" => :cpu_pct,
        "server_mem" => :mem_pct,
        "server_disk" => :disk_pct,
        "server_temp" => :temp_max,
        # Database: connessioni = conteggio assoluto (soglia vs max_connections del DB, non una
        # percentuale), lag replica = secondi. Host senza DB → valore nil → nessun alert.
        "server_db_connections" => :db_connections,
        "server_db_connection_usage" => :db_connection_usage_pct,
        "server_replication_lag" => :db_replication_lag_seconds,
        "server_data_volume_disk" => :data_volume_disk_pct,
        "server_inode" => :inode_pct
      }.freeze

      RESTART_WINDOW = 10.minutes
      RESTART_THRESHOLD = 3

      def initialize(host:, payload:)
        @host = host
        @payload = payload || {}
      end

      def call
        normalized = Normalize.call(payload: @payload)

        was_down = @host.status_down?
        previous_security_updates = @host.security_updates_available
        previous_failed = Array(@host.failed_services)
        previous_smart = @host.smart_data.is_a?(Hash) ? @host.smart_data : {}
        previous_db_up = database_reachable(@host.database_snapshot)
        previous_replication_outage = replication_outage(@host)
        previous_container_restart_outage = container_restart_outage(@host)
        # Container: lo stato per la transizione sono i nomi attesi (finestra di memoria su
        # Servers::ContainerSample, esclusi idle-managed ed effimeri) più l'outage già segnato
        # sull'host. Catturati PRIMA della transazione, come gli altri previous_* (insert_containers
        # aggiungerebbe già il nuovo set, falsando il confronto).
        previous_container_outage = container_outage(@host)
        # Finestra ancorata al recorded_at del push, non all'orologio: un agent che recupera un
        # arretrato manderebbe campioni vecchi e con Time.current la memoria risulterebbe già scaduta.
        expected_container_names = Servers::ContainerSample.expected_names_for(@host, now: normalized.recorded_at)
        new_container_outage = compute_container_outage(normalized, expected_container_names)
        new_replication_outage = compute_replication_outage(normalized, previous_replication_outage)
        new_container_restart_outage = compute_container_restart_outage(normalized, previous_container_restart_outage)

        inserted = false
        ApplicationRecord.transaction do
          update_host!(normalized, new_container_outage, new_replication_outage, new_container_restart_outage)
          inserted = insert_sample(normalized)
          insert_containers(normalized) if inserted
        end

        # Journal FUORI dalla transazione: una riga avvelenata sfuggita allo scrub non deve abortire
        # il campione. NON gated su `inserted`: un retry (stesso recorded_at) non deve perdere le
        # entries — hanno idempotenza propria su [host, cursor].
        persist_journal(normalized)

        notify_alerts(normalized, was_down:, previous_security_updates:,
                      previous_failed:, previous_smart:, previous_db_up:,
                      previous_container_outage:, new_container_outage:,
                      previous_replication_outage:, new_replication_outage:,
                      previous_container_restart_outage:, new_container_restart_outage:)
        broadcast_realtime
        Result.ok(@host)
      end

      private

      # Broadcast Turbo (sempre dopo il commit): replace riga fleet + pill header + page-refresh della show.
      # Anche su sample duplicato (retry agent): update_host! ha comunque rinfrescato lo snapshot.
      # Un push = un host = un bundle di broadcast al minuto — costo trascurabile.
      def broadcast_realtime
        Servers::Broadcast.row(@host)
        Servers::Broadcast.stats(@host.organization_id)
        Servers::Broadcast.refresh(@host)
      end

      def update_host!(normalized, container_outage, replication_outage, container_restart_outage)
        sample = normalized.sample_attrs
        attrs = normalized.host_attrs.merge(
          agent_version: normalized.agent_version,
          last_seen_at: normalized.recorded_at,
          cpu_pct: sample[:cpu_pct], mem_pct: sample[:mem_pct], disk_pct: sample[:disk_pct],
          temp_max: sample[:temp_max],
          load_1: sample[:load_1], load_5: sample[:load_5], load_15: sample[:load_15],
          uptime_seconds: sample[:uptime_seconds],
          # I conteggi vengono da info.sv (presente ~ogni push); il dettaglio da data.systemd (~1/10).
          services_total: sample[:services_total], services_failed: sample[:services_failed],
          smart_data: normalized.smart_data,
          # Esito della transizione container (CYRA-248): sano {} / nomi caduti / motore giù. Snapshot
          # corrente come systemd/SMART, letto da Alerting::Content per il body dell'avviso.
          container_outage: container_outage,
          resource_pressure: normalized.resource_pressure,
          replication_outage: replication_outage,
          container_restart_outage: container_restart_outage
        )
        # Riarmo dell'avviso «dati fermi» (CYRA-676): al primo dato di nuovo fresco la memoria della
        # notifica si azzera, così il silenzio successivo avvisa di nuovo. Fresco si misura sulla
        # stessa soglia dell'allarme, non sui 90s del badge: un dato "quasi vecchio" non riarma.
        if @host.silent_alerted_at.present? &&
           normalized.recorded_at >= Time.current - Servers::Constants::SILENT_ALERT_AFTER_SECONDS.seconds
          attrs[:silent_alerted_at] = nil
        end
        # Fix flip-flop: la lista/nomi systemd derivano da data.systemd, presente solo ~1/10 dei push.
        # Sovrascriverli sempre azzererebbe lo stato 9 push su 10 (pannello vuoto + re-alert). Aggiorna
        # solo a sezione presente; altrimenti preserva l'ultimo stato noto.
        if normalized.systemd_present
          attrs[:systemd_services] = normalized.systemd_services
          attrs[:failed_services] = normalized.failed_service_names
        end
        # Stesso trattamento del blocco systemd: il collector Postgres OMETTE il blocco quando fallisce
        # (goroutine con recover), quindi sovrascrivere sempre svuoterebbe il pannello al primo intoppo.
        # Aggiorna solo a blocco presente; l'host senza DB non ha mai snapshot né ruolo.
        if normalized.database_present
          attrs[:database_snapshot] = normalized.database_snapshot
          attrs[:db_role] = normalized.database_snapshot["role"]
        end
        # Stesso trattamento di systemd/database: il conteggio container si scrive SOLO quando l'agent
        # ha potuto interrogare il motore (sezione presente). Assente = Docker giù/illeggibile →
        # preserva l'ultimo conteggio noto, altrimenti un intoppo del demone svuoterebbe il pannello
        # e la macchina resterebbe verde con zero container (CYRA-248).
        attrs[:containers_count] = normalized.containers.count { |container| container[:running] } if normalized.container_present
        # paused resta paused (niente alert/staleness); pending/up/down tornano up al push.
        attrs[:status] = :up unless @host.status_paused?
        @host.update!(attrs)
      end

      # Log nativi journald (dopo il commit, vedi #call). Entries e snapshot sono indipendenti:
      # un push può portare solo stream, solo snapshot, entrambi o nessuno.
      def persist_journal(normalized)
        insert_journal_entries(normalized)
        update_journal_snapshots(normalized)
      end

      def insert_journal_entries(normalized)
        return if normalized.journal_entries.empty?

        now = Time.current
        rows = normalized.journal_entries.map do |entry|
          entry.merge(host_id: @host.id, organization_id: @host.organization_id, created_at: now)
        end
        Servers::Journal::Entry.insert_all(rows, unique_by: %i[host_id cursor])
      end

      # Snapshot = stato corrente (jsonb sull'host), non storia: merge dei nuovi + rimozione delle unit
      # non più failed SOLO a sezione systemd presente (altrimenti lo stato è stale → si preserva).
      # update_column: bypassa validazioni estranee, come gli altri toggle jsonb del dominio.
      def update_journal_snapshots(normalized)
        current = @host.journal_snapshots.is_a?(Hash) ? @host.journal_snapshots : {}
        merged = current.merge(normalized.journal_snapshots)

        if normalized.systemd_present
          failed = normalized.failed_service_names.to_set
          merged = merged.select { |unit, _| failed.include?(unit) || normalized.journal_snapshots.key?(unit) }
        end

        return if merged == current

        @host.update_column(:journal_snapshots, merged)
      end

      # insert_all con unique_by: il retry dell'agent (stesso recorded_at) è un no-op → false.
      def insert_sample(normalized)
        rows = [ normalized.sample_attrs.merge(
          host_id: @host.id, organization_id: @host.organization_id,
          recorded_at: normalized.recorded_at, created_at: Time.current
        ) ]
        result = Servers::Sample.insert_all(rows, unique_by: %i[host_id recorded_at])
        result.rows.any?
      end

      def insert_containers(normalized)
        return if normalized.containers.empty?

        now = Time.current
        rows = normalized.containers.map do |container|
          container.merge(host_id: @host.id, recorded_at: normalized.recorded_at, created_at: now)
        end
        Servers::ContainerSample.insert_all(rows)
      end

      # Esito della transizione dei container per lo snapshot host + l'alert, confrontando i nomi
      # attesi col push corrente. Tutti spariti = motore giù (un solo avviso); alcuni = i nomi caduti.
      # Info NON disponibile (sezione container assente: motore Docker giù/illeggibile) con container
      # noti → motore giù.
      #
      # Lo snapshot è STABILE, non un lampo di transizione: la memoria sta in
      # ContainerSample.expected_names_for, che tiene un nome atteso per tutta la finestra anche
      # quando non compare più nei push. Senza memoria il confronto col set ORA ridotto tornerebbe {}
      # e il job asincrono (che legge lo snapshot host, non un fermo-immagine) troverebbe l'outage già
      # ripulito → avviso senza nome. A differenza di prima la memoria SCADE: un container gestito da
      # idle-sleep, un `_replaced_` di Kamal o un one-off `exec` non tornano mai, e restando attesi in
      # eterno facevano crescere la lista senza fine (un avviso nuovo a ogni variazione).
      #
      # Ordinamento: `missing` è ordinato perché l'uguaglianza col push precedente decide se avvisare,
      # e un ordine ballerino sarebbe un avviso spurio a ogni push.
      def compute_container_outage(normalized, expected_names)
        unless normalized.container_present
          return { "engine_down" => true } if expected_names.any?

          return {}
        end

        current_names = running_container_names(normalized)
        # CYRA-774 — un rilascio ferma la versione vecchia quando la nuova è già in piedi: quel nome
        # è stato sostituito, non è caduto, e non tornerà mai. Vale sia che il container sparisca dal
        # push sia che resti elencato da fermo finché Kamal non lo pota — ciò che conta è che un'altra
        # versione dello stesso servizio stia girando adesso.
        missing = Servers::ContainerSample
                  .reject_replaced_by_release(expected_names - current_names, current_names)
                  .sort

        return { "engine_down" => true } if current_names.empty? && expected_names.any?
        return {} if missing.empty?

        # CYRA-489 — l'istante in cui l'outage è cominciato, per poter dire «da 12 minuti»
        # nell'avviso. Se l'insieme dei caduti non è cambiato si conserva il primo: un container in
        # più non deve far ripartire il cronometro.
        previous = container_outage(@host)
        since = previous["names"] == missing ? previous["since"] : nil
        { "names" => missing, "since" => (since.presence || normalized.recorded_at).to_s }
      end

      def notify_alerts(normalized, was_down:, previous_security_updates:,
                        previous_failed:, previous_smart:, previous_db_up:,
                        previous_container_outage:, new_container_outage:,
                        previous_replication_outage:, new_replication_outage:,
                        previous_container_restart_outage:, new_container_restart_outage:)
        return if @host.status_paused?

        enqueue_alert("server_up") if was_down
        notify_security_updates(normalized, previous_security_updates)
        notify_failed_services(normalized, previous_failed)
        notify_smart(normalized, previous_smart)
        notify_database(normalized, previous_db_up)
        notify_containers(normalized, previous_container_outage, new_container_outage)
        notify_replication(previous_replication_outage, new_replication_outage)
        notify_container_restarts(previous_container_restart_outage, new_container_restart_outage)
        notify_thresholds(normalized)
      end

      # Avvisa alla TRANSIZIONE verso un outage container (gemello di notify_smart/notify_database):
      # un nuovo stato "rotto" (motore giù o nomi caduti) rispetto al push precedente → UN solo
      # avviso per host (il body li elenca da container_outage). Stato invariato = muto (non ripete
      # ogni push col motore giù).
      #
      def notify_containers(normalized, previous_outage, new_outage)
        if container_outage_alarming?(new_outage)
          enqueue_alert("server_container_down") unless new_outage == previous_outage
          return
        end

        return unless container_outage_alarming?(previous_outage)

        enqueue_alert("server_container_up") if containers_returned?(normalized, previous_outage)
      end

      # Il rientro si annuncia SOLO se è successo davvero qualcosa di buono: il motore è tornato, o
      # almeno uno dei nomi caduti ricompare fra i container in esecuzione. Un outage che si svuota
      # perché i nomi sono scaduti dalla finestra di memoria chiude in silenzio: nessuno è tornato,
      # e spacciarlo per un recupero sarebbe una bugia.
      #
      # CYRA-774 — vale anche il guasto riparato PUBBLICANDO: il nome caduto non tornerà mai, ma al
      # suo posto gira una versione nuova dello stesso servizio, che è esattamente quello che
      # l'avviso prometteva. Cercare solo il nome esatto lo mancava sempre e lasciava l'avviso aperto
      # senza chiusura — un buco che il filtro dei sostituiti rende visibile: da lì in poi l'outage si
      # svuota da sé al primo push dopo il rilascio.
      def containers_returned?(normalized, previous_outage)
        return true if previous_outage["engine_down"] == true

        fallen = Array(previous_outage["names"])
        current_names = running_container_names(normalized)
        return true if fallen.intersect?(current_names)

        Servers::ContainerSample.reject_replaced_by_release(fallen, current_names).size < fallen.size
      end

      def container_outage_alarming?(outage)
        outage["engine_down"] == true || Array(outage["names"]).any?
      end

      def running_container_names(normalized)
        normalized.containers.filter_map { |container| container[:name] if container[:running] }
      end

      # Un restart counter è cumulativo per identità Docker. Confrontarlo con il minimo osservato
      # negli ultimi dieci minuti evita sia il falso positivo al primo push dopo un upgrade agent,
      # sia quello di un nuovo container Kamal che riusa il nome ma ha un id diverso.
      def compute_container_restart_outage(normalized, previous_outage)
        return previous_outage unless normalized.container_present

        candidates = normalized.containers.reject do |container|
          container[:idle_managed] || container[:name].match?(Servers::ContainerSample::EPHEMERAL_NAME)
        end
        return {} if candidates.empty?

        history = Servers::ContainerSample
                  .where(host_id: @host.id, recorded_at: (normalized.recorded_at - RESTART_WINDOW)...normalized.recorded_at)
                  .where(name: candidates.pluck(:name))
                  .select(:name, :container_id, :restart_count)
                  .group_by { |sample| [ sample.name, sample.container_id.presence ] }

        looping = candidates.filter_map do |container|
          identity = [ container[:name], container[:container_id].presence ]
          samples = history[identity]
          next if samples.blank?

          delta = container[:restart_count].to_i - samples.map(&:restart_count).min.to_i
          next if delta < RESTART_THRESHOLD

          {
            "name" => container[:name],
            "restarts" => delta,
            "oom_killed" => container[:oom_killed] == true
          }
        end.sort_by { |item| item["name"] }

        looping.any? ? { "containers" => looping } : {}
      end

      def notify_container_restarts(previous_outage, new_outage)
        if Array(new_outage["containers"]).any?
          enqueue_alert("server_container_restart_loop") if Array(previous_outage["containers"]).empty?
        elsif Array(previous_outage["containers"]).any?
          enqueue_alert("server_container_stable")
        end
      end

      # Una replica è valutabile soltanto dentro un cluster noto (stesso system_identifier su almeno
      # due host): così un PostgreSQL standalone non diventa erroneamente "replica mancante".
      def compute_replication_outage(normalized, previous_outage)
        return previous_outage unless normalized.database_present

        snapshot = normalized.database_snapshot
        return previous_outage unless snapshot&.dig("reachable") == true

        system_identifier = snapshot["system_identifier"].presence
        role = snapshot["role"]
        return previous_outage if system_identifier.nil? || !%w[primary standby].include?(role)

        peers = Servers::Host.where(organization_id: @host.organization_id).where.not(id: @host.id)
                             .where("database_snapshot ->> 'system_identifier' = ?", system_identifier).to_a
        return previous_outage if peers.empty?

        replication = snapshot["replication"].is_a?(Hash) ? snapshot["replication"] : {}
        if role == "standby"
          return {} if replication["streaming"] == true

          return { "role" => "standby", "system_identifier" => system_identifier }
        end

        expected = peers.count { |peer| peer.db_role == "standby" }
        return {} if expected.zero?

        streaming = Array(replication["replicas"]).count { |replica| replica["state"] == "streaming" }
        return {} if streaming >= expected

        { "role" => "primary", "system_identifier" => system_identifier,
          "expected" => expected, "streaming" => streaming }
      end

      def notify_replication(previous_outage, new_outage)
        if new_outage.present?
          enqueue_alert("server_replication_down") if previous_outage.empty?
        elsif previous_outage.present?
          enqueue_alert("server_replication_up")
        end
      end

      # Aggiornamenti di sicurezza pendenti: avvisa alla TRANSIZIONE nessuno→qualcuno (gemello di
      # notify_smart). Il conteggio che sale (3→5) non ri-avvisa: l'informazione «ce ne sono» è già
      # partita e il numero aggiornato sta sul pannello. -1/assente = sconosciuto (agent vecchio o
      # OS non-apt) → nessuna valutazione, come il blocco database assente.
      def notify_security_updates(normalized, previous_security_updates)
        current = normalized.host_attrs[:security_updates_available]
        return if current.nil? || current <= 0

        enqueue_alert("server_security_updates", value: current.to_f) if previous_security_updates.to_i <= 0
      end

      # CYRA-678 — le unit escluse per-host (ignored_service_patterns) non fanno scattare l'avviso:
      # il filtro sta qui e in Alerting::Content, MAI sullo stato raccolto — il pannello continua a
      # dire la verità.
      def notify_failed_services(normalized, previous_failed)
        new_failed = (normalized.failed_service_names - previous_failed)
                     .reject { |name| @host.ignored_service?(name) }
        enqueue_alert("server_service_failed") if new_failed.any?
      end

      # Avvisa solo alla TRANSIZIONE passed→non-passed di un device (non a ogni push col disco rotto).
      def notify_smart(normalized, previous_smart)
        failing = normalized.smart_data.select { |_dev, item| failing_smart?(item) }.keys
        previously_failing = previous_smart.select { |_dev, item| failing_smart?(item) }.keys

        enqueue_alert("server_smart_failing") if (failing - previously_failing).any?
      end

      def failing_smart?(item)
        status = item.is_a?(Hash) ? item["status"].to_s : ""
        status.present? && !status.casecmp?("PASSED")
      end

      # Database non raggiungibile: avvisa alla TRANSIZIONE verso reachable=false (gemello di
      # notify_smart), non a ogni push col DB giù. Lo stato precedente "sconosciuto" (host appena
      # registrato, o payload senza il flag) conta come sano → il primo push con DB giù avvisa;
      # i push successivi restano muti finché il DB non torna su e ricade.
      # Blocco assente (host senza DB, o collector fallito) → nessuna valutazione.
      def notify_database(normalized, previous_db_up)
        return unless normalized.database_present

        enqueue_alert("server_db_down") if normalized.database_snapshot["reachable"] == false && previous_db_up != false
      end

      def database_reachable(snapshot)
        snapshot.is_a?(Hash) ? snapshot["reachable"] : nil
      end

      def container_outage(host)
        host.container_outage.is_a?(Hash) ? host.container_outage : {}
      end

      def replication_outage(host)
        host.replication_outage.is_a?(Hash) ? host.replication_outage : {}
      end

      def container_restart_outage(host)
        host.container_restart_outage.is_a?(Hash) ? host.container_restart_outage : {}
      end

      # Pre-check: una EvaluateJob per event_type SOLO se almeno una regola org ha la soglia superata
      # (niente job no-op ogni minuto). Evaluate poi ri-filtra regola per regola.
      def notify_thresholds(normalized)
        thresholds = Alerting::Rule.enabled
                                   .where(organization_id: @host.organization_id, event_type: THRESHOLD_EVENTS.keys)
                                   .where.not(threshold: nil)
                                   .group(:event_type).minimum(:threshold)
        return if thresholds.empty?

        sample = normalized.sample_attrs
        thresholds.each do |event_type, min_threshold|
          value = sample[THRESHOLD_EVENTS.fetch(event_type)]
          next if value.nil? || value < min_threshold

          enqueue_alert(event_type, value: value.to_f)
        end
      end

      def enqueue_alert(event_type, value: nil)
        Alerting::EvaluateJob.perform_later(
          event_type: event_type, subject_type: "Servers::Host", subject_id: @host.id,
          project_id: nil, organization_id: @host.organization_id, value: value
        )
      end
    end
  end
end
