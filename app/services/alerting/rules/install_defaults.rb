# frozen_string_literal: true

module Alerting
  module Rules
    # Installa le regole di alerting di DEFAULT di un'organizzazione. Copre gli eventi uptime (sito giù /
    # ripristinato), i server (macchina della flotta giù / rientrata / servizio failed / disco SMART in
    # errore / database irraggiungibile) e gli agenti di automazione fermi: senza una regola default
    # l'evento apre l'incident/lo stato sul pannello ma non avvisa NESSUNO — Alerting::Evaluate non trova
    # regole e ritorna zero consegne (CYRA-207 per l'uptime, CYRA-242 per server e agenti). Le regole sono
    # org-wide (project/environment nil) → coprono tutti i monitor dell'org. Idempotente: se l'org ha già
    # una regola ORG-WIDE per quell'evento (anche disabilitata a mano) non la ri-crea. Chiamata dal
    # provisioning (Provision/seed) e dal backfill delle org esistenti.
    class InstallDefaults < ApplicationService
      # name = label canonico dell'event_type (member.alerting.event_types.*), coerente coi default
      # inglesi di Types::InstallDefaults. L'utente può rinominarle/disattivarle dalla pagina Avvisi.
      # Le soglie storiche restano opt-in. CYRA-515 installa invece tre guardrail prudenti espliciti
      # (slot DB 80%, volume 85%, inode 80%): senza una regola questi segnali verrebbero raccolti ma
      # scartati da Evaluate. Ogni default a soglia porta quindi il proprio valore.
      DEFAULTS = [
        { event_type: :uptime_down,           name: "Sito non raggiungibile" },
        { event_type: :uptime_up,             name: "Sito di nuovo raggiungibile" },
        { event_type: :uptime_slow,           name: "Uptime slow" },
        # CYRA-477: senza questo default un job schedulato che si ferma non avvisa nessuno (l'evento
        # "Cron mancato" esisteva nella tendina ma nessuna regola lo usava). Project-scoped come gli
        # uptime → org-wide copre tutti i cron. Copre le org NUOVE; le esistenti restano volutamente
        # scoperte finché non attivano la regola dal banner di copertura (index cron, Scenario 1) — il
        # backfill di massa nasconderebbe quel banner. Attivandola, i cron già fermi ricevono subito
        # l'avviso (Crons::AlertActiveMissed).
        { event_type: :cron_missed,           name: "Cron missed" },
        { event_type: :server_down,           name: "Macchina non raggiungibile" },
        { event_type: :server_up,             name: "Macchina ripristinata" },
        { event_type: :server_service_failed, name: "Servizio in errore" },
        { event_type: :server_smart_failing,  name: "Disco in errore" },
        { event_type: :server_container_down, name: "Contenitore caduto" },
        # CYRA-512: gemello di "Macchina ripristinata". Senza una regola default l'avviso di rientro non
        # partirebbe mai e la caduta resterebbe l'ultima parola sul feed, anche a guasto chiuso.
        { event_type: :server_container_up,   name: "Contenitori tornati su" },
        { event_type: :server_db_down,        name: "Database non raggiungibile" },
        { event_type: :server_db_connection_usage, name: "Connessioni database alte", threshold: 80 },
        { event_type: :server_data_volume_disk, name: "Spazio dati quasi pieno", threshold: 85 },
        { event_type: :server_inode, name: "Inode quasi esauriti", threshold: 80 },
        # CYRA-676: due segnali già raccolti che non avvisavano nessuno. Gli aggiornamenti di
        # sicurezza erano in UI e azionabili ma senza event_type; il silenzio (macchina che risponde
        # con dati fermi) era documentato come pericoloso nel modello e restava muto.
        { event_type: :server_security_updates, name: "Aggiornamenti di sicurezza in attesa" },
        { event_type: :server_silent,           name: "Dati fermi" },
        # CYRA-775: senza questa regola il rifiuto resterebbe scritto solo nei log, e la scelta di
        # NON dichiarare giù quelle macchine sarebbe indistinguibile da un sistema che tace. throttle
        # a 1h (non i 5' di default) per la stessa ragione di agents_host_stale: il giro gira ogni
        # minuto e un episodio lungo ripeterebbe l'avviso venticinque volte.
        { event_type: :server_ingest_rejected,  name: "Dati delle macchine respinti", throttle_seconds: 3600 },
        # CYRA-679: predittivo, il valore è la stima in giorni (non una soglia percentuale).
        { event_type: :server_disk_forecast,    name: "Spazio dati in esaurimento" },
        { event_type: :server_replication_down, name: "Replica scollegata" },
        { event_type: :server_replication_up, name: "Replica ripristinata" },
        { event_type: :server_container_restart_loop, name: "Contenitore che si riavvia in continuazione" },
        { event_type: :server_container_stable, name: "Contenitore di nuovo stabile" },
        # CYAG-22: Kubernetes clusters watched by closeyourit-kube.
        { event_type: :cluster_down,               name: "Cluster muto" },
        { event_type: :cluster_up,                 name: "Cluster di nuovo raggiungibile" },
        { event_type: :cluster_node_not_ready,     name: "Macchina del cluster non pronta" },
        { event_type: :cluster_node_pressure,      name: "Macchina del cluster sotto sforzo" },
        { event_type: :cluster_workload_crashloop, name: "App che riparte di continuo" },
        { event_type: :cluster_workload_degraded,  name: "App a metà" },
        { event_type: :agents_stalled,        name: "Automazione bloccata" },
        { event_type: :agents_host_failing,   name: "Macchina in errore" },
        # CYRA-450: una macchina ferma senza regola non avviserebbe nessuno. throttle a 1h (non i 5' di
        # default): una macchina morta resta morta e il giro di rilevamento ogni 15' la ri-notificherebbe
        # 4 volte l'ora — il throttle collassa i re-alert in ~1/h mantenendo tempestivo il primo avviso.
        { event_type: :agents_host_stale,     name: "Macchina silenziosa", throttle_seconds: 3600 },
        # CYRA-147: statistiche, idee, attività, dataset — senza una regola default nessuno riceverebbe
        # questi avvisi appena creata l'org. Il PICCO di traffico (analytics_traffic_spike) resta opt-in:
        # spesso è benigno (campagna, bot), lo attiva chi lo vuole. Tutti senza soglia.
        { event_type: :analytics_traffic_drop,     name: "Traffic drop" },
        { event_type: :idea_created,               name: "New idea" },
        { event_type: :idea_commented,             name: "New idea comment" },
        { event_type: :workload_due_soon,          name: "Task due soon" },
        { event_type: :dataset_training_completed, name: "Training completed" },
        { event_type: :dataset_training_failed,    name: "Training failed" },
        # CYRA-506: una vulnerabilità nuova senza regola non avviserebbe nessuno. Il filtro di
        # gravità NON sta qui ma su min_level della regola, che l'utente alza se vuole solo le
        # critiche; il ticket automatico invece parte solo da high in su, sempre.
        { event_type: :vulnerability_new,          name: "New vulnerability" },
        { event_type: :runtime_eol,                name: "Runtime end of life" },
        # CYRA-528: senza una regola il rilievo SEO grave verrebbe scritto e poi nessuno lo saprebbe
        # finché non apre la pagina — cioè, di solito, dopo che il traffico è già sceso.
        { event_type: :seo_issue_new,              name: "Nuovo rilievo SEO" }
      ].freeze

      def initialize(organization:, created_by: nil)
        @organization = organization
        @created_by = created_by
      end

      def call
        # UNA query per tutti i default, non una per ciascuno: `exists?` dentro il ciclo faceva scattare
        # Prosopite sul percorso di registrazione (N+1 su `alerting_rules`). Oggetti (non `pluck`) perché
        # il cast dell'enum restituisce le chiavi come stringhe, mentre `pluck` darebbe gli interi grezzi.
        rules = Alerting::Rule
                .where(organization_id: @organization.id, event_type: DEFAULTS.map { |d| d[:event_type] })
                .select(:event_type, :project_id, :environment_id)
                .to_a

        # "Già installata" dipende da come Alerting::Evaluate seleziona le regole per quel tipo di evento:
        # - eventi PROJECT-SCOPED (uptime_*): solo una regola ORG-WIDE (project/environment nil) copre
        #   tutti i monitor; una scoped su un progetto/ambiente lascia gli altri scoperti → non conta come
        #   installata e la org-wide va comunque creata.
        # - eventi ORG-SCOPED (server_*/agents_*): Evaluate#matching_org_rules IGNORA project/environment,
        #   quindi QUALSIASI regola per quell'evento (anche scoped, anche disabilitata a mano) copre già
        #   tutta l'org. Crearne una org-wide sarebbe un doppione (Evaluate consegnerebbe due volte, il
        #   dedup_key non distingue le regole) o riaccenderebbe un avviso spento di proposito.
        any_scope = rules.map(&:event_type).to_set
        org_wide = rules.select { |r| r.project_id.nil? && r.environment_id.nil? }.map(&:event_type).to_set

        DEFAULTS.each do |default|
          event_type = default[:event_type].to_s
          installed = Alerting::Rule.org_scoped_event?(event_type) ? any_scope : org_wide
          next if installed.include?(event_type)

          Alerting::Rule.create!(
            organization: @organization, created_by: @created_by,
            event_type: default[:event_type], name: default[:name], enabled: true,
            # Throttle esplicito solo dove serve (agents_host_stale = 1h); altrimenti il default del model (5').
            **default.slice(:threshold, :throttle_seconds)
          )
        end
        Result.ok(@organization)
      end
    end
  end
end
