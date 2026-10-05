# frozen_string_literal: true

module Alerting
  # Snapshot umano (title/body/url) + project di una notifica, derivato da (event_type, subject).
  # Lo snapshot è congelato sulla notifica → resta leggibile anche se il subject cambia in seguito.
  # details (CYRA-323): elenco completo opzionale dietro "mostra dettagli" (container/servizi/dischi
  # caduti) — il body porta solo conteggio+host, mai la lista intera. nil quando non applicabile.
  Content = Data.define(:title, :body, :url, :project, :details)

  # Riaperta con `class` e non col blocco di Data.define (CYRA-797): dentro quel blocco una costante
  # finirebbe su Alerting, non su Alerting::Content — il cref di module_eval resta quello lessicale.
  class Content
    # Il registro: event_type → metodo della sua famiglia. Aggiungere un avviso è una riga qui più un
    # metodo corto sotto; i tipi che costruiscono lo stesso testo condividono il metodo (CYRA-797).
    EVENT_BUILDERS = {
      "error_new" => :error, "error_regression" => :error, "error_spike" => :error,
      "uptime_down" => :uptime_incident, "uptime_up" => :uptime_incident,
      "uptime_ssl_expiring" => :uptime_ssl_expiring,
      "uptime_slow" => :uptime_slow,
      "cron_missed" => :cron_missed,
      "metric_threshold" => :metric_threshold,
      "measurement_threshold" => :measurement_threshold,
      "log_alert" => :log_alert,
      "server_down" => :server_reachability, "server_up" => :server_reachability,
      "server_cpu" => :server_threshold, "server_mem" => :server_threshold,
      "server_disk" => :server_threshold, "server_temp" => :server_threshold,
      "server_service_failed" => :server_service_failed,
      "server_smart_failing" => :server_smart_failing,
      "server_silent" => :server_silent,
      "server_security_updates" => :server_security_updates,
      "server_data_volume_disk" => :server_resource_pressure, "server_inode" => :server_resource_pressure,
      "server_disk_forecast" => :server_disk_forecast,
      "server_db_down" => :server_db_down,
      "server_db_connections" => :server_db_connections,
      "server_db_connection_usage" => :server_db_connection_usage,
      "server_replication_lag" => :server_replication_lag,
      "server_replication_down" => :server_replication_down,
      "server_replication_up" => :server_replication_up,
      "server_container_down" => :server_container_down,
      "server_container_up" => :server_container_up,
      "server_container_restart_loop" => :server_container_restart_loop,
      "server_container_stable" => :server_container_stable,
      "server_ingest_rejected" => :server_ingest_rejected,
      "embedding_down" => :embedding_down,
      "ai_unavailable" => :ai_availability, "ai_available" => :ai_availability,
      "cache_unavailable" => :cache_unavailable,
      "cluster_down" => :cluster_reachability, "cluster_up" => :cluster_reachability,
      "cluster_node_not_ready" => :cluster_node, "cluster_node_pressure" => :cluster_node,
      "cluster_workload_crashloop" => :cluster_workload, "cluster_workload_degraded" => :cluster_workload,
      "agents_stalled" => :agents_stalled,
      "agents_host_failing" => :agents_host, "agents_host_stale" => :agents_host,
      "vulnerability_new" => :vulnerability_new,
      "runtime_eol" => :runtime_eol,
      "seo_issue_new" => :seo_issue_new,
      "secret_read" => :secret_access, "secret_denied" => :secret_access,
      "analytics_traffic_drop" => :analytics_traffic, "analytics_traffic_spike" => :analytics_traffic,
      "idea_created" => :idea_created,
      "idea_commented" => :idea_commented,
      "workload_due_soon" => :workload_due_soon,
      "dataset_training_completed" => :dataset_training_completed,
      "dataset_training_failed" => :dataset_training_failed
    }.freeze

    def initialize(details: nil, **kwargs)
      super(details: details, **kwargs)
    end

    def self.for(event_type:, subject:)
      event_type = event_type.to_s
      builder = EVENT_BUILDERS[event_type]
      raise ArgumentError, "Alerting::Content: event_type non supportato #{event_type.inspect}" if builder.nil?

      send(builder, event_type, subject)
    end

    class << self
      private

      def routes
        Rails.application.routes.url_helpers
      end

      # Tutti gli avvisi di macchina hanno la stessa forma: titolo con l'host, link alla sua scheda,
      # nessun progetto (sono dell'organizzazione). `key` è il ramo i18n, `body_key` la variante del
      # testo, il resto sono le interpolazioni del body.
      def host_alert(host, key:, body_key: "body", details: nil, **body_args)
        new(
          title: I18n.t("alerting.content.#{key}.title", host: host.name),
          body: I18n.t("alerting.content.#{key}.#{body_key}", **body_args),
          url: routes.member_monitoring_server_path(host),
          project: nil,
          details: details
        )
      end

      # Il nome di rete se c'è, altrimenti quello scritto dall'utente: senza ripiego la frase esce
      # con un buco al posto della macchina.
      def host_label(host)
        host.hostname.presence || host.name
      end

      # Gli snapshot dell'host sono jsonb liberi: un sotto-oggetto può mancare o non essere una mappa
      # (database non sondabile, agent vecchio). Meglio una mappa vuota che un errore in un avviso.
      def snapshot(source, *path)
        value = path.reduce(source) { |current, key| current.is_a?(Hash) ? current[key] : nil }
        value.is_a?(Hash) ? value : {}
      end

      # Gli avvisi dell'organizzazione (subject = Organizations::Organization, project nil): cambia
      # solo dove mandano chi legge.
      def organization_alert(organization, key:, url:)
        new(
          title: I18n.t("alerting.content.#{key}.title", organization: organization.name),
          body: I18n.t("alerting.content.#{key}.body"),
          url: url,
          project: nil
        )
      end

      def error(event_type, group)
        # Sulla regressione mostra la release che ha CAUSATO il reopen (regressed_in_release,
        # CYRA-44), non la generica release più recente osservata — può essere un residuo pre-fix.
        body = group.culprit.to_s
        if event_type == "error_regression" && group.regressed_in_release.present?
          release = I18n.t("alerting.content.error_regression.release", release: group.regressed_in_release)
          body = [ body.presence, release ].compact.join(" · ")
        end
        new(title: I18n.t("alerting.content.#{event_type}.title", error: group.title),
            body: body,
            url: routes.member_monitoring_error_group_path(group),
            project: group.project)
      end

      def uptime_incident(event_type, incident)
        # `target` e non `url` (CYRA-151): un monitor tcp/dns/ping non ha url — col solo url l'avviso
        # arriverebbe senza bersaglio (" non risponde — incident aperto.").
        monitor = incident.monitor
        new(title: I18n.t("alerting.content.#{event_type}.title", project: monitor.project.name),
            body: I18n.t("alerting.content.#{event_type}.body", target: monitor.target),
            url: routes.member_monitoring_monitor_path(monitor),
            project: monitor.project)
      end

      def uptime_ssl_expiring(_event_type, monitor)
        days_left = monitor.ssl_expires_at ? ((monitor.ssl_expires_at - Time.current) / 1.day).floor : nil
        new(title: I18n.t("alerting.content.uptime_ssl_expiring.title", project: monitor.project.name),
            body: I18n.t("alerting.content.uptime_ssl_expiring.body", url: monitor.url, days: days_left),
            url: routes.member_monitoring_monitor_path(monitor),
            project: monitor.project)
      end

      def uptime_slow(_event_type, monitor)
        # Usa `target` (non url): un monitor non-web non ha una url. La soglia superata è quella
        # configurata sul monitor.
        new(title: I18n.t("alerting.content.uptime_slow.title", project: monitor.project.name),
            body: I18n.t("alerting.content.uptime_slow.body", target: monitor.target,
                                                              threshold: monitor.latency_threshold_ms),
            url: routes.member_monitoring_monitor_path(monitor),
            project: monitor.project)
      end

      def cron_missed(_event_type, monitor)
        # CYRA-477 Scenario 3: dire DA QUANTO è fermo (dall'ultimo check-in), non solo la cadenza.
        # last_check_in_at nil = atteso ma mai arrivato → `body_never`, senza inventare una durata.
        since = monitor.last_check_in_at &&
                ActionController::Base.helpers.time_ago_in_words(monitor.last_check_in_at)
        new(title: I18n.t("alerting.content.cron_missed.title", name: monitor.name,
                                                                project: monitor.project.name),
            body: I18n.t("alerting.content.cron_missed.#{since ? 'body' : 'body_never'}",
                         interval: monitor.expected_interval_minutes, since: since),
            url: routes.member_monitoring_cron_monitors_path,
            project: monitor.project)
      end

      def metric_threshold(_event_type, group)
        new(title: I18n.t("alerting.content.metric_threshold.title",
                          subtype: I18n.t("member.metrics.subtype.#{group.subtype}", default: group.subtype.to_s),
                          project: group.project.name),
            body: group.title,
            url: routes.member_monitoring_metric_group_path(group),
            project: group.project)
      end

      def measurement_threshold(_event_type, evaluation)
        value = evaluation.result
        new(title: I18n.t("alerting.content.measurement_threshold.title", name: value["name"]),
          body: I18n.t("alerting.content.measurement_threshold.body", statistic: I18n.t("alerting.measurements.statistics.#{value['statistic']}"), value: value["value"], unit: value["unit"]),
          url: routes.member_project_path(evaluation.project), project: evaluation.project,
          details: value.slice("quantile", "threshold", "comparison", "diagnostics"))
      end

      def log_alert(_event_type, entry)
        # subject = Logs::Entry: il livello è leggibile via i18n (member.alerting.levels.*), il body è
        # il messaggio del log, l'url la show della singola riga (CYRA-55).
        new(title: I18n.t("alerting.content.log_alert.title",
                          level: I18n.t("member.alerting.levels.#{entry.level}"),
                          project: entry.project.name),
            body: entry.message,
            url: routes.member_monitoring_log_entry_path(entry),
            project: entry.project)
      end

      def server_reachability(event_type, host)
        host_alert(host, key: event_type, hostname: host_label(host))
      end

      def server_threshold(event_type, host)
        # Il body usa lo SNAPSHOT dell'host (colonne denormalizzate appena aggiornate dall'ingest
        # che ha generato l'evento).
        value = { "server_cpu" => host.cpu_pct, "server_mem" => host.mem_pct,
                  "server_disk" => host.disk_pct, "server_temp" => host.temp_max }.fetch(event_type)
        host_alert(host, key: event_type, value: value)
      end

      def server_service_failed(_event_type, host)
        # CYRA-678 — le unit escluse per-host non compaiono nell'avviso, e il body NOMINA le unit
        # (chi legge alle tre di notte non deve aprire il pannello per sapere cos'è caduto).
        failed = Array(host.failed_services).reject { |name| host.ignored_service?(name) }
        names = failed.first(5).join(", ")
        names += "…" if failed.size > 5
        host_alert(host, key: "server_service_failed", details: failed,
                         count: failed.size, host: host.name, names: names)
      end

      def server_smart_failing(_event_type, host)
        failing = host.smart_data.filter_map do |device, item|
          device if item.is_a?(Hash) && item["status"].present? && !item["status"].to_s.casecmp?("PASSED")
        end
        host_alert(host, key: "server_smart_failing", details: failing,
                         count: failing.size, host: host.name)
      end

      def server_silent(_event_type, host)
        age = host.data_age
        duration = age ? ActionController::Base.helpers.distance_of_time_in_words(age) : "—"
        host_alert(host, key: "server_silent", hostname: host_label(host), duration: duration)
      end

      def server_security_updates(_event_type, host)
        # CYRA-676 — il conteggio si rilegge dallo snapshot host (come server_smart_failing con
        # smart_data): fra accodamento e consegna può essere salito, e il numero fresco è quello vero.
        host_alert(host, key: "server_security_updates",
                         count: host.security_updates_available.to_i, host: host.name)
      end

      def server_resource_pressure(event_type, host)
        pressure = snapshot(host.resource_pressure, event_type == "server_inode" ? "inode" : "data_volume_disk")
        host_alert(host, key: event_type, details: [ pressure["name"] ].compact,
                         mountpoint: pressure["mountpoint"] || pressure["name"] || "—",
                         value: pressure["pct"] || "—")
      end

      def server_disk_forecast(_event_type, host)
        # CYRA-679 — stima e mountpoint riletti dallo stato sull'host (come server_data_volume_disk fa
        # con resource_pressure): fra accodamento e consegna la stima può essersi aggiornata.
        state = snapshot(host.disk_forecast_state)
        pressure = snapshot(host.resource_pressure, "data_volume_disk")
        host_alert(host, key: "server_disk_forecast",
                         days: state["days"] ? state["days"].round : "—",
                         mountpoint: pressure["mountpoint"] || pressure["name"] || "—",
                         value: state["current_pct"] || pressure["pct"] || "—")
      end

      def server_db_down(_event_type, host)
        # Database sull'host (CYRA-181): subject = Servers::Host come gli altri server_*, project nil.
        host_alert(host, key: "server_db_down", hostname: host_label(host))
      end

      def server_db_connections(_event_type, host)
        # Body dallo SNAPSHOT database dell'host (appena aggiornato dall'ingest che ha generato
        # l'evento), come per le soglie cpu/mem/disk/temp.
        connections = snapshot(host.database_snapshot, "connections")
        host_alert(host, key: "server_db_connections",
                         value: connections["total"], max: connections["max"] || "—")
      end

      def server_db_connection_usage(_event_type, host)
        connections = snapshot(host.database_snapshot, "connections")
        usable = connections["max"].to_i - connections["reserved"].to_i
        pct = usable.positive? ? ((connections["total"].to_f / usable) * 100).round(1) : nil
        host_alert(host, key: "server_db_connection_usage",
                         value: connections["total"], usable: usable, pct: pct || "—")
      end

      def server_replication_lag(_event_type, host)
        host_alert(host, key: "server_replication_lag",
                         value: snapshot(host.database_snapshot, "replication")["lag_seconds"])
      end

      def server_replication_down(_event_type, host)
        outage = snapshot(host.replication_outage)
        host_alert(host, key: "server_replication_down",
                         body_key: outage["role"] == "primary" ? "body_primary" : "body_standby",
                         expected: outage["expected"], streaming: outage["streaming"])
      end

      def server_replication_up(_event_type, host)
        host_alert(host, key: "server_replication_up")
      end

      def server_container_down(_event_type, host)
        # Container spariti fra due push (CYRA-248): engine_down = tutti spariti insieme / motore non
        # interrogabile → un solo avviso sul motore, altrimenti si contano i nomi caduti.
        outage = snapshot(host.container_outage)
        return container_engine_down(host) if outage["engine_down"]

        # CYRA-489 — «da quanto» è la prima domanda di chi legge alle tre di notte. `since` lo scrive
        # l'ingest quando l'outage nasce; sugli avvisi vecchi manca, e lì resta la frase di prima.
        names = Array(outage["names"])
        since = outage["since"].presence && (Time.zone.parse(outage["since"].to_s) rescue nil)
        host_alert(host, key: "server_container_down", body_key: since ? "body_since" : "body",
                         details: names, count: names.size, host: host.name,
                         duration: since && ActionController::Base.helpers.distance_of_time_in_words(since, Time.current))
      end

      def container_engine_down(host)
        host_alert(host, key: "server_container_down.engine_down", hostname: host_label(host))
      end

      def server_container_up(_event_type, host)
        # Rientro dei container (CYRA-512): gemello di server_up. Nessun elenco — l'outage sull'host è
        # già stato azzerato quando questo avviso parte, e ripescare i nomi darebbe una lista vuota.
        host_alert(host, key: "server_container_up", hostname: host_label(host))
      end

      def server_container_restart_loop(_event_type, host)
        containers = Array(snapshot(host.container_restart_outage)["containers"])
        details = containers.map do |container|
          I18n.t("alerting.content.server_container_restart_loop.detail",
                 name: container["name"], restarts: container["restarts"])
        end
        host_alert(host, key: "server_container_restart_loop", details: details,
                         count: containers.size, host: host.name)
      end

      def server_container_stable(_event_type, host)
        host_alert(host, key: "server_container_stable")
      end

      def server_ingest_rejected(_event_type, organization)
        # CYRA-775 — il rifiuto è NOSTRO e riguarda tutte le sonde dell'organizzazione insieme, non
        # una macchina: punta alla flotta, dove si vede quali dati sono fermi e da quando.
        organization_alert(organization, key: "server_ingest_rejected",
                                         url: routes.member_monitoring_servers_path)
      end

      def embedding_down(_event_type, organization)
        # Punta alle impostazioni AI dell'organizzazione, da dove si vede lo stato del servizio.
        organization_alert(organization, key: "embedding_down", url: routes.member_agents_path)
      end

      def cache_unavailable(_event_type, organization)
        # CYRA-846 — la memoria temporanea vive su una macchina della flotta: si punta lì, dove
        # si vede quale host è caduto e da quando.
        organization_alert(organization, key: "cache_unavailable",
                                         url: routes.member_monitoring_servers_path)
      end

      # CYAG-22 — every cluster alert links to the cluster page, where "what is wrong now" lists it.
      def cluster_alert(cluster, key:, **args)
        new(
          title: I18n.t("alerting.content.#{key}.title", cluster: cluster.name, **args),
          body: I18n.t("alerting.content.#{key}.body", cluster: cluster.name, **args),
          url: routes.member_monitoring_cluster_path(cluster),
          project: nil
        )
      end

      def cluster_reachability(event_type, cluster) = cluster_alert(cluster, key: event_type)

      def cluster_node(event_type, node) = cluster_alert(node.cluster, key: event_type, node: node.name)

      def cluster_workload(event_type, workload)
        cluster_alert(workload.cluster, key: event_type, workload: workload.name, namespace: workload.namespace.name,
                                        reason: workload.last_reason.presence || "-",
                                        ready: workload.ready, desired: workload.desired)
      end

      def ai_availability(event_type, organization)
        # CYRA-712 — punta ai servizi collegati: la chiave sta lì, ed è lì che si rimette a posto.
        organization_alert(organization, key: event_type, url: routes.member_integrations_path)
      end

      def agents_stalled(_event_type, organization)
        # Punta alla lista degli host di automazione, dove si vedono le lavorazioni ferme.
        organization_alert(organization, key: "agents_stalled", url: routes.member_agents_path)
      end

      def agents_host(event_type, host)
        # CYRA-282/CYRA-450 — la macchina che butta via il lavoro e quella ferma: subject = Agents::Host,
        # si punta alla SUA scheda, dove rendimento e ultimo battito dicono cosa sta succedendo.
        new(title: I18n.t("alerting.content.#{event_type}.title", host: host.hostname),
            body: I18n.t("alerting.content.#{event_type}.body"),
            url: routes.member_agent_path(host),
            project: nil)
      end

      def vulnerability_new(_event_type, finding)
        # CYRA-506 — il titolo porta gravità e coordinate perché è ciò che decide se guardare adesso o
        # dopo; il corpo dice la mossa concreta (aggiorna a X) o che non ce n'è una: OSV non sempre
        # dichiara una versione che risolve, e dirlo è più utile che tacere.
        body_key = finding.fixable? ? "body" : "body_unfixable"
        new(title: I18n.t("alerting.content.vulnerability_new.title",
                          severity: I18n.t("member.monitoring.vulnerabilities.severity.#{finding.severity}"),
                          package: finding.package_coordinates),
            body: I18n.t("alerting.content.vulnerability_new.#{body_key}",
                         fixed_version: finding.fixed_version, advisory: finding.display_id),
            url: routes.member_monitoring_vulnerability_path(finding),
            project: finding.project)
      end

      def seo_issue_new(_event_type, issue)
        # CYRA-528 — il titolo porta il nome del controllo e l'indirizzo, perché è quello che decide se
        # guardare adesso; il corpo dice perché conta, con le parole della guida e non del codice.
        new(title: I18n.t("alerting.content.seo_issue_new.title", check: issue.label, url: issue.url.to_s),
            body: issue.explanation.presence || I18n.t("alerting.content.seo_issue_new.body_fallback"),
            url: routes.member_monitoring_seo_path(issue),
            project: issue.project)
      end

      def runtime_eol(_event_type, status)
        # CYRA-506 — la versione di linguaggio non riceve più patch di sicurezza. Punta alla tab dei
        # runtime, dove stanno tutte insieme.
        new(title: I18n.t("alerting.content.runtime_eol.title", runtime: status.name, version: status.version),
            body: I18n.t("alerting.content.runtime_eol.body", date: I18n.l(status.eol_on, format: :long)),
            url: routes.runtimes_member_monitoring_vulnerabilities_path,
            project: status.project)
      end

      def secret_access(event_type, event)
        # CYRA-77 — il VALORE non entra mai (queste stringhe finiscono in un'email e magari su un
        # webhook esterno): si dice chi, quale nome e dove, e si rimanda al registro del progetto.
        # Attore, nome e ambiente sono opzionali sul model → ognuno ha la sua parola di ripiego, o un
        # accesso di sistema uscirebbe come una frase con un buco in mezzo.
        actor = event.actor&.email || I18n.t("alerting.content.secret_access.system")
        name = event.name.presence || I18n.t("alerting.content.secret_access.any_name")
        environment = event.environment&.label || I18n.t("alerting.content.secret_access.any_environment")
        new(title: I18n.t("alerting.content.#{event_type}.title", name: name, project: event.project.name),
            body: I18n.t("alerting.content.#{event_type}.body", actor: actor, environment: environment),
            url: routes.member_project_secret_events_path(event.project),
            project: event.project)
      end

      def analytics_traffic(event_type, project)
        # Traffico del sito (CYRA-147): subject = il progetto stesso (nessun modello incident). L'url
        # punta alla dashboard analytics filtrata sul progetto (params[:project_id]).
        new(title: I18n.t("alerting.content.#{event_type}.title", project: project.name),
            body: I18n.t("alerting.content.#{event_type}.body"),
            url: routes.member_monitoring_analytics_path(project_id: project.id),
            project: project)
      end

      def idea_created(_event_type, idea)
        # Nuova idea (CYRA-147): body = il titolo dell'idea, url alla sua pagina.
        new(title: I18n.t("alerting.content.idea_created.title", project: idea.project.name),
            body: idea.title,
            url: routes.member_idea_path(idea),
            project: idea.project)
      end

      def idea_commented(_event_type, comment)
        # Nuovo commento a un'idea (CYRA-147): i commenti non hanno una pagina propria, si punta
        # all'idea commentata.
        idea = comment.idea
        new(title: I18n.t("alerting.content.idea_commented.title", project: idea.project.name),
            body: idea.title,
            url: routes.member_idea_path(idea),
            project: idea.project)
      end

      def workload_due_soon(_event_type, action)
        # Attività in scadenza (CYRA-147): team-scoped → project nil (come i server_*).
        new(title: I18n.t("alerting.content.workload_due_soon.title", title: action.title),
            body: I18n.t("alerting.content.workload_due_soon.body"),
            url: routes.member_workload_action_path(action),
            project: nil)
      end

      def dataset_training_completed(_event_type, training)
        # Addestramento completato (CYRA-147): project via il dataset.
        new(title: I18n.t("alerting.content.dataset_training_completed.title", dataset: training.dataset.name),
            body: I18n.t("alerting.content.dataset_training_completed.body"),
            url: routes.member_dataset_training_path(training.dataset, training),
            project: training.dataset.project)
      end

      def dataset_training_failed(_event_type, training)
        # Addestramento fallito (CYRA-147): body = il messaggio d'errore snapshottato sul training.
        new(title: I18n.t("alerting.content.dataset_training_failed.title", dataset: training.dataset.name),
            body: training.error_message.presence ||
                  I18n.t("alerting.content.dataset_training_failed.body"),
            url: routes.member_dataset_training_path(training.dataset, training),
            project: training.dataset.project)
      end
    end
  end
end
