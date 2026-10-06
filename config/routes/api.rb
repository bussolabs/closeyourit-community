# API pubblica a token bearer (SDK, CI, agenti). Canale macchina: nessuna sessione, nessuna vista.

# --- API v1 (Fase 1) — autenticazione a token bearer per-progetto ---
namespace :api do
  namespace :v1 do
    namespace :coworkers do
      post "readiness", to: "worker#readiness"
      post "claims", to: "worker#claim"
      post "runs/:run_id/events", to: "worker#events"
    end

    namespace :otlp do
      resources :authorizations, only: :create
    end

    # Lookup consumati dai client (contratto rules/lookup-tables.md)
    namespace :types do
      resources :ticket_statuses, only: :index
      resources :ticket_priorities, only: :index
      resources :platforms, only: :index
      resources :environments, only: :index
    end

    # Ingest a token bearer (CI / segnali custom) — confluisce nello stesso pipeline degli SDK.
    resources :projects, only: [] do
      namespace :otlp do
        resources :traces, only: :create, format: false
        resources :metrics, only: :create, format: false
        resources :logs, only: :create, format: false
      end
      resources :events, only: :create
      resources :metrics, only: :create   # ingest performance (query/metodi lenti)
      resources :logs, only: :create      # ingest log strutturati (stream, batch)
      resources :pageviews, only: :create # ingest web analytics (pageview cookieless, batch)
      resources :web_vitals, only: :create # ingest velocità dai visitatori veri (CYRA-538)
      resources :replays, only: :create   # ingest chunk di session replay (rrweb, batch)
      resources :helpdesk_requests, only: :create # a visitor of the project's site asks for help (CYRA-940)
      resource :analytics, only: :show    # stats API di lettura (snapshot completo del range)
      resources :releases, only: %i[index create]  # release tracking (upsert da CI)
      resources :deploy_failures, only: :create   # CYRA-871: ticket quando la produzione non è in piedi dopo il deploy
      resources :coverage_reports, only: %i[index create], path: "coverage" # CYSK-26: estratto copertura da CI (upsert per branch)
      resources :usages, only: %i[index create] # Server-only ingest and authenticated read-back.
      # Heartbeat cron: il job fa check-in su POST .../crons/:slug/check_in (upsert monitor al 1° ping).
      post "crons/:slug/check_in", to: "cron_check_ins#create"
    end

    namespace :crashes do
      resources :reports, only: %i[index show destroy]
      resources :attachments, only: :destroy do
        get :download, on: :member
      end
    end

    namespace :session_health do
      resources :sessions, only: :index
      resources :summaries, only: :index
    end

    resources :measurement_series, only: %i[index show] do
      resources :points, only: :index, module: :measurement_series
      resource :aggregation, only: :show, module: :measurement_series
    end

    resources :traces, only: %i[index show] do
      resources :spans, only: :index, module: :traces
      resources :logs, only: :index, module: :traces
      resources :errors, only: :index, module: :traces
    end

    # Triage degli errori (lettura + stato come sub-resource singleton, mai verbi).
    resources :error_groups, only: %i[index show] do
      resources :events, only: :index, module: :error_groups
      resource :resolution, only: %i[update destroy], module: :error_groups  # PUT resolve, DELETE reopen
      resource :mute, only: %i[update destroy], module: :error_groups        # PUT ignore, DELETE reopen
    end

    # Lettura dei gruppi-metrica (query/metodi lenti) del progetto del token.
    resources :metric_groups, only: %i[index show] do
      resources :samples, only: :index, module: :metric_groups
    end

    # Lettura dei log del progetto del token (stream filtrabile).
    resources :log_entries, only: :index

    # Ingest degli agent di server monitoring (bearer = enrollment token org-scoped, NON
    # per-progetto → fuori da resources :projects).
    namespace :servers do
      resources :samples, only: :create
      resources :action_claims, only: :create
      resources :actions, only: :update
    end
    # Kubernetes cluster observer (closeyourit-kube): bearer = per-cluster cyi_k_ token (CYAG-22).
    namespace :clusters do
      resources :snapshots, only: :create
    end
    # Automator (closeyourit-automator): cyi_a_ è solo bootstrap host; pull agenti e report run
    # richiedono cyi_ah_. Entrambi sono org-scoped e restano fuori da resources :projects.
    resources :hosts, only: :create
    # Struttura repo da clonare servita all'host autenticato (cyi_ah_) per il provisioning OneClick.
    namespace :agent_host do
      resource :workspace_manifest, only: :show
      # Bundle skill versionato pinnato (repo/ref/version/digest) servito all'host cyi_ah_ per il clone del plugin.
      resource :skill_manifest, only: :show
      # The organization's Claude credential for the host's Claude sessions (CYAU-224).
      resource :claude_credential, only: :show
      resource :openrouter_credential, only: :show # CYAU-228 — the key OpenCode reviews with
    end
    # Coda agenti host-scoped (CYAU-84): appiattita, senza agent_id nell'URL. L'host è identificato dal token
    # cyi_ah_ (Current.agent_host); scope/capability/claim sono host-only (token host-bound + ProjectScope +
    # Eligibility). Il catalogo di enumerazione `GET /api/v1/agents` è stato rimosso con i typed agent
    # (MT-9): l'host scopre cosa gli compete dal workspace_manifest, non da un elenco di agenti.
    resource :ticket_queue, only: :show, module: :agents
    resources :ticket_queue_claims, path: "ticket_queue/claims", only: :create, module: :agents
    # Presa in carico atomica (CYRA-588): sceglie il candidato e lo prende in carico in un colpo solo,
    # così due postazioni sulla stessa coda ottengono ticket diversi. Additiva: le due rotte sopra
    # restano il percorso in due passi.
    resources :ticket_queue_next_claims, path: "ticket_queue/next_claim", only: :create, module: :agents
    resources :ticket_queue_deferrals, path: "ticket_queue/deferrals", only: :create, module: :agents
    resources :agent_attempts, only: [], path: "agent_attempts" do
      resource :result, only: :update, module: :agents, controller: "attempt_results"
      # Canale del fallimento (CYRA-282): la macchina riporta che la sessione è morta, col motivo.
      resource :failure, only: :create, module: :agents, controller: "attempt_failures"
    end
    post "leases", to: "leases/acquisitions#create"
    post "leases/:ticket/renew", to: "leases/renewals#create", format: false
    post "leases/:ticket/release", to: "leases/releases#create", format: false
    # La policy dei limiti resta leggibile dall'host. La prenotazione via HTTP
    # (POST /api/v1/limits/reservations) è stata rimossa con i typed agent (MT-9): risolveva lo scope
    # dall'agente e dal suo target, autorità che non esiste più, e non aveva clienti — l'automator
    # prenota in locale e il claim host-scoped chiama Agents::Limits::Reserve direttamente.
    resource :limits, only: :show
  end

  # Ingest Sentry-compatibile (path dettato dagli SDK, FUORI da /api/v1; auth via DSN public key).
  # format: false — gli SDK Sentry non mandano MAI un'estensione: senza il flag /envelope.json
  # instradava (format json), aprendo una forma dell'indirizzo su cui il rate limit non scattava (CYRA-251).
  post ":project_id/minidump", to: "ingest#minidump", format: false
  post ":project_id/envelope", to: "ingest#envelope", format: false
  post ":project_id/store",    to: "ingest#store",    format: false
end
