# frozen_string_literal: true

module Realtime
  # Registro centrale dei nomi-stream Turbo: fonte di verità UNICA per write-side (broadcast_*_to)
  # e read-side (turbo_stream_from). Ogni nome è una String tenant-prefissata `org:<org_id>:...`,
  # quindi l'isolamento per organizzazione è garantito a livello di nome-stream (Turbo firma il
  # nome lato view -> nessuna sottoscrizione cross-tenant). NON hardcodare nomi-stream altrove:
  # passare sempre da questi helper.
  #
  # Il prefisso d'org però isola SOLO fra tenant diversi. Dentro un'org la visibilità è per progetto
  # (Authorization::VisibleScope), quindi uno stream org-wide che trasporta HTML renderizzato dal
  # broadcaster consegna a ogni membro anche i contenuti dei progetti che non può vedere — è stato
  # il caso della board ticket (CYRA-257). Regola che ne consegue: uno stream org-wide può portare
  # SOLO segnali di page-refresh (ogni viewer ri-fetcha con la propria sessione, quindi si ri-scopa
  # da sé). QUALSIASI HTML renderizzato va su uno stream PER PROGETTO, anche un replace su target
  # per-record: nel DOM è no-op per chi quel record non ce l'ha in pagina, ma il payload HTML viaggia
  # comunque sul wire ed è leggibile nei frame WebSocket (titolo errore, nome/URL monitor di un altro
  # progetto) — CYRA-271. La index si iscrive a un nome per ogni progetto visibile (come project_board).
  #
  # Derivazione dell'org_id (verificata su schema/associazioni reali):
  #  - helper che ricevono un'organizzazione    -> organization.id
  #  - ticket / monitor / error_group / metric_group: nessuna colonna organization_id diretta,
  #    si deriva via record.project.organization_id (belongs_to :project -> belongs_to :organization).
  module Streams
    module_function

    def coworker(puck, locale)
      "#{tenant(puck.organization_id)}coworker:#{puck.account_id}:#{puck.id}:#{locale}"
    end

    # Board ticket di UN progetto: page-refresh dei soli viewer che quel progetto lo vedono.
    # Per-progetto e NON org-wide, per la ragione nel commento del modulo. La board si iscrive a un
    # nome per ogni progetto visibile (member/tickets/index.html.erb).
    def project_board(project)
      "#{tenant(project.organization_id)}board:project:#{project.id}"
    end

    # Stream del singolo ticket (timeline, stato, assignee, watchers, contatore commenti).
    def ticket(ticket)
      "#{tenant_via_project(ticket)}ticket:#{ticket.id}"
    end

    # Pagina/lista uptime dell'organizzazione: SOLO page-refresh (ri-fetch per-viewer). Le righe
    # renderizzate NON vanno qui — vedi project_uptime.
    def uptime(organization)
      "#{tenant(organization)}uptime"
    end

    # Righe monitor di UN progetto: replace della riga (HTML) ai soli viewer che quel progetto lo
    # vedono. Per-progetto e NON org-wide (come project_board): sullo stream org-wide il replace
    # per-record è no-op nel DOM ma l'HTML arriva comunque a chi non vede il progetto (CYRA-271).
    def project_uptime(project)
      "#{tenant(project.organization_id)}uptime:project:#{project.id}"
    end

    # Stream del singolo monitor (check/attempts, incidents).
    def monitor(monitor)
      "#{tenant_via_project(monitor)}monitor:#{monitor.id}"
    end

    # Stream log dell'organizzazione (prepend righe nuove).
    def logs(organization)
      "#{tenant(organization)}logs"
    end

    # Lista gruppi d'errore dell'organizzazione: SOLO page-refresh (ri-fetch per-viewer). Le righe
    # renderizzate NON vanno qui — vedi project_errors.
    def errors(organization)
      "#{tenant(organization)}errors"
    end

    # Righe gruppo-errore di UN progetto: replace della riga (HTML) ai soli viewer che quel progetto
    # lo vedono. Per-progetto per la stessa ragione di project_uptime (CYRA-271).
    def project_errors(project)
      "#{tenant(project.organization_id)}errors:project:#{project.id}"
    end

    # Stream del singolo gruppo d'errore (occorrenze/eventi nella show).
    def error_group(group)
      "#{tenant_via_project(group)}error_group:#{group.id}"
    end

    # --- liste per progetto (CYRA-822) ------------------------------------------------------
    #
    # Secondo livello del segnale di aggiornamento delle tre liste ad alto volume. Lo stream
    # org-wide resta e serve chi guarda l'intera organizzazione; questi servono chi sta guardando
    # UN progetto, e sono la ragione per cui una raffica nel progetto B non fa più ri-chiedere la
    # lista a chi sta guardando A. Il produttore emette su entrambi i livelli (due broadcast,
    # indipendenti dal numero di progetti); la pagina si iscrive a uno solo dei due, secondo il
    # filtro attivo — vedi Member::Monitoring::Indexable#live_stream_projects.
    #
    # Ci viaggia SOLO il segnale di page-refresh, mai HTML: il nome è per progetto, ma chi vi si
    # iscrive lo fa perché quel progetto lo vede, e il contenuto se lo ri-scopa da sé con la propria
    # sessione. `errors:list:project:` è distinto da `errors:project:` di proposito: quest'ultimo
    # trasporta la riga renderizzata del triage (CYRA-271) e ha un pubblico più largo.
    def project_errors_list(project)
      "#{tenant(project.organization_id)}errors:list:project:#{project.id}"
    end

    def project_metrics_list(project)
      "#{tenant(project.organization_id)}metrics:list:project:#{project.id}"
    end

    def project_logs_list(project)
      "#{tenant(project.organization_id)}logs:list:project:#{project.id}"
    end

    # Lista gruppi-metrica dell'organizzazione (righe + stats).
    def metrics(organization)
      "#{tenant(organization)}metrics"
    end

    # Stream del singolo gruppo-metrica (campioni nella show).
    def metric_group(group)
      "#{tenant_via_project(group)}metric_group:#{group.id}"
    end

    # Dashboard analytics di UN progetto (page-refresh Turbo della show: header/grafico/tabelle/chip).
    # Per-progetto, NON org-wide: un pageview di un progetto ri-fetcha solo i viewer di QUELLA
    # dashboard. org via colonna diretta del progetto (come server_host con host.organization_id).
    def analytics(project)
      "#{tenant(project.organization_id)}analytics:project:#{project.id}"
    end

    # Scheda di UN agente (CYRA-823): il segnale che la sua attività è cambiata. Risorsa org-scoped
    # come server_host — l'host ha organization_id diretto, niente progetto. Ci viaggia SOLO un
    # segnale, mai HTML: `agents.view` è org-level ma i ticket che l'agente sta lavorando si vedono
    # per progetto, quindi due membri della stessa organizzazione devono ricevere due pagine diverse.
    # Ognuno se la ri-chiede con la propria sessione, e il filtro lo rifà il controller.
    def agent_host(host)
      "#{tenant(host.organization_id)}agent_host:#{host.id}"
    end

    # Scheda di UN sito osservato dal cockpit SEO (CYRA-824): il segnale che il suo controllo è
    # cambiato — cominciato, finito o fallito. org via progetto, come monitor ed error_group.
    # Ci viaggia SOLO un segnale, mai HTML: chi vede il sito lo vede perché vede il progetto, ma
    # sulla stessa scheda «Rilancia» e «Modifica» compaiono solo a chi ha `seo.manage`. Due persone
    # davanti alla stessa pagina devono quindi riceverne due versioni diverse, e chi rende il
    # messaggio non sa per chi lo sta rendendo: ognuno se la ri-chiede con la propria sessione.
    def seo_site(site)
      "#{tenant_via_project(site)}seo_site:#{site.id}"
    end

    # Fleet servers dell'organizzazione (righe host + stats aggregate). Risorsa org-scoped:
    # l'host ha organization_id diretto, niente project.
    def servers(organization)
      "#{tenant(organization)}servers"
    end

    # One Kubernetes cluster page (CYAG-22): page refresh after every snapshot.
    def cluster(cluster)
      "#{tenant(cluster.organization_id)}cluster:#{cluster.id}"
    end

    # Stream del singolo host: page-refresh Turbo della show (morph). org via colonna diretta.
    def server_host(host)
      "#{tenant(host.organization_id)}server_host:#{host.id}"
    end

    # Cron monitor list of the organization: page-refresh only (per-viewer re-fetch). Rendered rows
    # never go here, see project_crons.
    def crons(organization)
      "#{tenant(organization)}crons"
    end

    # Monitor rows of ONE project: the replaced row (HTML) reaches only the viewers who see that
    # project, like project_uptime and project_errors (CYRA-271, CYRA-1040).
    def project_crons(project)
      "#{tenant(project.organization_id)}crons:project:#{project.id}"
    end

    # Stream del singolo cron monitor (prepend check-in nella show, labels).
    def cron_monitor(monitor)
      "#{tenant_via_project(monitor)}cron_monitor:#{monitor.id}"
    end

    # Presenza PER-VIEWER: ogni account ha il suo stream presenza. La lista che vi arriva è
    # filtrata (Presence::Cohort) ai soli online con cui `account` condivide un contesto —
    # niente più stream org-wide condiviso (che mostrava l'intera org a tutti). Precedente
    # identico già in uso per le notifiche: `alerting:notifications:#{account.id}`.
    def presence_for(organization, account)
      "#{tenant(organization)}presence:account:#{account.id}"
    end

    # Viewers di una risorsa specifica (badge "chi sta guardando"). `resource` identificato
    # via to_gid_param (signed global id param), così lo stream è unico per record.
    def viewers(organization, resource)
      "#{tenant(organization)}viewers:#{resource.to_gid_param}"
    end

    # Thread di una conversazione di chat (append messaggi, typing, read-receipt). org via colonna
    # denormalizzata della conversazione (nessun join).
    def chat_conversation(conversation)
      "#{tenant(conversation.organization_id)}chat:conversation:#{conversation.id}"
    end

    # Inbox chat per-account (badge non-letti + riordino lista conversazioni). Account-scoped come
    # lo stream notifiche.
    def chat_inbox(organization, account)
      "#{tenant(organization)}chat:inbox:#{account.id}"
    end

    # Conversazione con l'assistente help (append bolle utente/assistente + streaming della risposta
    # a chunk). org via colonna denormalizzata della conversazione. La conversazione è già posseduta
    # dall'account (ownership), quindi il nome tenant-prefissato basta all'isolamento.
    def assistant_conversation(conversation)
      "#{tenant(conversation.organization_id)}assistant:conversation:#{conversation.id}"
    end

    # --- helper interni (privati) -----------------------------------------------------------

    # Prefisso tenant `org:<id>:`. Accetta un record Organizations::Organization oppure un id grezzo.
    def tenant(organization)
      "org:#{organization.respond_to?(:id) ? organization.id : organization}:"
    end

    # Prefisso tenant per record che raggiungono l'org via progetto.
    def tenant_via_project(record)
      "org:#{record.project.organization_id}:"
    end

    private_class_method :tenant, :tenant_via_project
  end
end
