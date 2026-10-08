# Area utenti autenticata (/member). È il canale più grande: il namespace, l'indirizzo esplicito
# della Home e — buon ultimo — il catch-all che rende la 404 di prodotto. L'ordine dentro questo
# file conta: il catch-all deve restare DOPO ogni rotta member reale.

# --- Area organizzazione (Fase C) ---
namespace :member do
  # Before the resources: "activity" must not be read as a Puck id (CYRA-1026).
  get "coworkers/activity", to: "coworker_activity#index", as: :coworker_activity
  resources :coworkers, only: %i[index show create update] do
    resources :runs, only: %i[create update], controller: "coworker_runs" do
      post :approve, on: :member
      post :repeat, on: :member
      # The person takes the task's browser and gives it back (CYRA-1016).
      member do
        %w[take give point type].each { |action| post "control/#{action}", to: "coworker_controls##{action}", as: "control_#{action}" }
      end
    end
    # Actions a Puck proposed and the rules that decide them (CYRA-1010, CYRA-1017).
    resources :proposals, only: [], controller: "coworker_proposals" do
      post :confirm, on: :member
      post :discard, on: :member
    end
    resources :rules, only: :update, param: :action_kind, controller: "coworker_rules"
    # Repeated tasks, watch checks, learned notes and the monthly budget (CYRA-1001, 1011, 1012, 1027).
    resources :schedules, only: %i[create update destroy], controller: "coworker_schedules"
    resource :watch, only: :update, controller: "coworker_watches"
    resources :memory_notes, only: :update, path: "notes", controller: "coworker_memory_notes"
    resource :budget, only: :update, controller: "coworker_budgets"
    # Apps, sites, the screen of a task, procedures and connected computers (CYRA-1014, 1015, 1016, 1013, 1029).
    resources :connections, only: %i[create update destroy], controller: "coworker_connections"
    resources :sites, only: %i[create destroy], controller: "coworker_sites"
    resources :procedures, only: %i[create destroy], controller: "coworker_procedures" do
      post :start, on: :member
      post :repeat, on: :member
    end
    resources :devices, only: :destroy, controller: "coworker_devices"
  end
  # Ricerca rapida cross-area della topbar (CYRA-634): risponde dentro un Turbo Frame e parte
  # sempre dagli scope visibili dell'account corrente.
  get "search", to: "searches#index", as: :search

  # Azioni veloci inline della home (CYRA-178): un controller dedicato orchestra i service di dominio
  # esistenti e risponde in Turbo Stream ricalcolando il feed. I controller di dominio restano invariati.
  namespace :home do
    # CYRA-630 — qui c'erano le sette decisioni della riga del feed, prese da cinque posti con
    # cinque regole diverse; adesso si decide solo da `approvals/decision`.
    # CYRA-658 — e qui c'erano anche «rispondi» e «vota», le due azioni veloci del feed a quattro
    # elenchi. Il feed non c'è più: rispondere a una domanda si fa dalla scheda della decisione o
    # dal ticket, votare un'idea dalla pagina delle idee.

    # CYRA-657 — i modi per NON decidere adesso. Nessuno di questi decide niente: non toccano il
    # record e non avvisano nessuno. Le decisioni vere restano dietro l'unica porta di
    # `approvals/decision`.
    post "card/skip",  to: "cards#skip",  as: :card_skip
    post "card/defer", to: "cards#defer", as: :card_defer
    post "card/back",  to: "cards#back",  as: :card_back

    # Plancia delle approvazioni (CYRA-262, CYRA-592): una riga per lavorazione e una colonna per
    # ciascuna delle cinque fasi, raggruppata per progetto. `?item=famiglia:uuid` apre la singola
    # richiesta col suo pannello di decisione (link condivisibile).
    get  "approvals",          to: "approvals#index"
    post "approvals/decision", to: "approvals#decide", as: :approvals_decision
    # CYRA-284: accettazione in blocco delle card selezionate nella coda (`keys[]`).
    post "approvals/bulk",     to: "approvals#bulk", as: :approvals_bulk
    # CYRA-867 — annulla tutte le lavorazioni aperte dell'organizzazione (owner e admin).
    post "approvals/cancel", to: "workflow_cancellations#create", as: :approvals_cancel_all
    # CYRA-903 — the sidebar badge, loaded lazily so the queue never slows down a page.
    get  "approvals/count", to: "approval_counts#show", as: :approvals_count
    # CYRA-591 — la scheda di UNA lavorazione, su una pagina sua. La chiave della card è
    # "famiglia:uuid": qui viaggia SPACCHETTATA in due segmenti, così l'indirizzo resta leggibile e
    # condivisibile (`/approvals/agent_plan/<uuid>`) invece di portarsi dietro i due punti.
    # Sta DOPO `approvals/bulk` e `approvals/decision`: sono path fissi e devono vincere sul
    # segmento variabile, o `:kind` se li mangerebbe.
    get  "approvals/:kind/:id", to: "approvals#show", as: :approvals_item
    # CYRA-899 — the row preview on the board, loaded lazily into its own frame.
    get  "approvals/:kind/:id/preview", to: "approvals#preview", as: :approvals_item_preview
  end

  resources :shared_secrets, path: "shared/secrets", only: %i[index create destroy] do
    resources :delegations, only: %i[create destroy], module: :shared_secrets
    resources :versions, only: :update, module: :shared_secrets
    post :impact, on: :member
    # Rivela il valore in chiaro di un value condiviso SOLO su richiesta esplicita (CYRA-202): la
    # matrice non rende più i valori nel sorgente. Identifica il value via `value_id`, registra
    # l'accesso (audit "revealed").
    get :reveal, on: :member
  end
  resources :shared_secret_assets, path: "shared/files", only: %i[index new create destroy] do
    get :download, on: :member
    # Storico versioni + rollback dei file segreti condivisi (CYRA-136, parita con project/personal).
    get :versions, on: :member
    post :rollback, on: :member
    resources :delegations, only: %i[create destroy], module: :shared_secret_assets
  end
  # Vault PERSONALE per-utente (gemello per-org del vault di progetto Secrets::). Struttura FLAT,
  # ownership (nessuna permission key), scoping per Current.account. Controller flat (come project_secrets).
  resources :personal_secrets, path: "personal/secrets", only: %i[index create destroy], controller: "personal_secrets" do
    resources :versions, only: :index, controller: "personal_secret_versions" do
      post :rollback, on: :member
      # Rivela il valore in chiaro di UNA versione storica (CYRA-204): lo storico non rende più i
      # valori nel sorgente. Ownership, registra l'accesso (audit "read").
      get :reveal, on: :member
    end
    # Rivela il valore in chiaro di un secret personale SOLO su richiesta esplicita (CYRA-204): la lista
    # non rende più i valori nel sorgente. Ownership (nessun gate), registra l'accesso (audit "read").
    get :reveal, on: :member
  end
  # File segreti PERSONALI (CYRA-133): gemello per-file del vault personale. Ownership, download solo
  # come attachment. Versions/rollback/purge come member routes sul controller (pattern project_secret_assets).
  resources :personal_secret_assets, path: "personal/files", only: %i[index new create destroy], controller: "personal_secret_assets" do
    member do
      get :download
      get :versions
      post :rollback
      delete :purge
    end
  end
  # Space "Vault" (CYRA-133): landing overview + picker di progetto. L'area member non ha un progetto
  # corrente persistente → al livello Progetto si sceglie qui e si atterra sulle pagine secret/file
  # ESISTENTI del progetto (pattern Member::Monitoring::AnalyticsController).
  get "vault", to: "vault#overview", as: :vault
  # «Cosa puoi fare qui» (CYRA-430): le funzioni dell'area una per una, ciascuna con un esempio e il
  # collegamento al posto dove si usa. Sta DENTRO il Vault e non fra le guide: chi cerca cosa sa fare
  # quest'area la cerca qui, non in un'altra parte del prodotto. Nessun gate (non espone valori).
  get "vault/capabilities", to: "vault/capabilities#index", as: :vault_capabilities
  resources :vault_projects, only: :index, path: "vault/projects"
  # Pagina Audit del Vault (CYRA-135): elenco filtrabile degli eventi sui secret org-scoped.
  get "vault/audit", to: "vault/audit#index", as: :vault_audit
  # Ricerca cross-progetto delle variabili per NOME (CYRA-137): "dove è usata VAR_X" tra i
  # progetti visibili. Nessun permesso secrets.read — non espone alcun valore.
  get "vault/variables", to: "vault/variable_search#index", as: :vault_variables
  # «Da sistemare» (CYRA-428): la lista unica, ordinata per rischio, di ciò che sui segreti richiede
  # un'azione — anomalie, rotazioni scadute o vicine, richieste in attesa. Sostituisce le tre pagine
  # qui sotto, i cui indirizzi restano validi e portano qui.
  get "vault/attention", to: "vault/attention#index", as: :vault_attention
  # "Cosa non torna" (CYRA-137, riscritta in CYRA-409): le anomalie dei secret una per una. Da
  # CYRA-428 l'elenco vive dentro «Da sistemare» e questo indirizzo ci porta; le azioni che marcano
  # e annullano un'assenza «voluta» restano qui (anti-BOLA nel controller, permesso secrets_audit.view).
  get "vault/health", to: "vault/health#index", as: :vault_health
  post "vault/health/anomalies/:id/acknowledge", to: "vault/health#acknowledge", as: :acknowledge_vault_health_anomaly
  delete "vault/health/anomalies/:id/acknowledge", to: "vault/health#restore", as: :restore_vault_health_anomaly
  # «Valore in comune» (CYRA-777): la pagina di conferma di una proposta di consolidamento — cosa
  # sparisce dai progetti, con che nome ciascuno continuerà a leggerlo, cosa nasce
  # nell'organizzazione. Non è un elenco: le proposte si leggono dalle righe di «Da sistemare», qui
  # si decide UNA proposta alla volta. Anti-BOLA nel controller (proposta risolta dentro l'org
  # corrente), gate shared_secrets.manage — spostare un valore nell'organizzazione è il gesto di chi
  # tiene i secret dell'organizzazione.
  resources :vault_consolidations, only: :show, path: "vault/consolidations",
            controller: "vault/consolidations" do
    member do
      post :promote
      post :dismiss
    end
  end
  # "Cosa ruotare" (CYRA-138, Fase 4 pezzo A1): i secret con una policy di rotazione in scadenza o
  # scaduta. Da CYRA-428 vivono dentro «Da sistemare» e questo indirizzo ci porta.
  get "vault/rotation", to: "vault/rotation#index", as: :vault_rotation
  # "Richieste in attesa" (CYRA-138, Fase 4 pezzo C2b): le Secrets::ChangeRequest pending su cui
  # l'account può agire + azioni di decisione. NON resources nested sotto progetto (una CR non
  # appartiene alla navigazione di un singolo progetto, è cross-progetto come health/rotation) —
  # solo member actions su :id, anti-BOLA risolto nel controller dentro current_visible_projects.
  # Da CYRA-428 l'elenco vive dentro «Da sistemare» e l'index ci porta; le azioni restano qui.
  resources :vault_change_requests, only: :index, path: "vault/requests",
            controller: "vault/change_requests" do
    member do
      post :approve
      post :reject
      post :cancel
    end
  end

  # Panoramiche dei gruppi (CYRA-139, riviste da CYRA-521): la pagina d'ingresso di un gruppo coi suoi
  # numeri vivi, resa da un solo controller parametrizzato dal group_id di route → member_<id>_path.
  # Sono la prima voce dentro il gruppo aperto, non più la destinazione di un cambio d'area.
  get "observability",  to: "overviews#show", as: :observability,  defaults: { group_id: "observability" }
  get "infrastructure", to: "overviews#show", as: :infrastructure, defaults: { group_id: "infrastructure" }
  get "product",        to: "overviews#show", as: :product,        defaults: { group_id: "product" }
  get "alerts",         to: "overviews#show", as: :alerts,         defaults: { group_id: "alerts" }
  get "automation",     to: "overviews#show", as: :automation,     defaults: { group_id: "automation" }
  get "seo",            to: "overviews#show", as: :seo,            defaults: { group_id: "seo" }
  get "settings",       to: "overviews#show", as: :settings,       defaults: { group_id: "settings" }
  # Gli indirizzi che spariscono, tenuti come redirect finché qualcuno li ha nei segnalibri: /application
  # era la panoramica di ticket e progetti insieme, /growth uno spazio intero per una pagina sola
  # (CYRA-455). NB: /member/product resta lo stesso indirizzo ma cambia contenuto — era la panoramica
  # della conoscenza, ora è quella del prodotto. È la fine della collisione Product/Prodotto (CYRA-330):
  # un nome, un posto solo. La conoscenza ha il suo, /member/knowledge.
  # Registro attività (CYRA-745): «chi ha fatto cosa e quando» in un posto solo. Unifica in LETTURA i
  # registri di lavoro, ticket, permessi e Vault — quello dei permessi non era letto da nessuna pagina.
  get "activity", to: "activity#index", as: :activity

  get "application", to: redirect("/member/product")
  get "growth", to: redirect("/member/monitoring/analytics")
  resources :members, only: %i[index edit update destroy] do
    member do
      patch :role
      get   :access
      patch :access, action: :update_access
      post  :access_preview, path: "preview" # schema what-if (owner/god): ricalcola i permessi effettivi pendenti
    end
  end
  resources :invitations, only: %i[new create destroy] do
    member { post :resend }
  end
  resource :organization, only: %i[edit update]
  # Guidance a livello ORGANIZZAZIONE (CYRA-75): references + procedures LOCALI. Controller flat.
  # scope statico (l'org è quella corrente, non un id nel path) → /member/organization/guidance*.
  # Gate organization.manage.
  scope :organization, as: :organization do
    resource :guidance, only: :show, controller: "organization_guidance"
    # The organization's AI provider, models and token cap (CYRA-914). Gate ai.manage.
    resource :ai, only: %i[show update], controller: "organization_ai" do
      post :test
    end
    resources :guidance_references, path: "references", only: %i[new create edit update destroy], controller: "organization_guidance_references" do
      patch :reorder, on: :collection
    end
    resources :guidance_procedures, path: "procedures", only: %i[new create edit update destroy], controller: "organization_guidance_procedures" do
      patch :reorder, on: :collection
    end
  end
  resource :preferences, only: %i[show update]
  # B25 — the collapsed page header, saved by the header's own toggle.
  resource :page_header_preference, only: :update, path: "preferences/header"
  resources :dismissed_notices, only: :create, path: "preferences/notices"
  # The Support button in the footer (CYRA-935).
  resources :support_requests, only: %i[index create], path: "support"
  # Tab "Notifiche" delle impostazioni account: matrice cadenze per-notifica × canale.
  # Controller FLAT Member::AlertingPreferencesController invariato (un Member::Alerting ombreggerebbe ::Alerting).
  resource :notification_preferences, only: %i[show update],
           path: "preferences/notifications", controller: "alerting_preferences"
  # Tab "Telegram" delle impostazioni account: collegamento del proprio account al bot ufficiale (show)
  # + scollega (destroy). Il collegamento avviene via webhook /start; qui si mostra stato/guida e si scollega.
  resource :telegram_connection, only: %i[show destroy], path: "preferences/telegram"
  # Gruppo Telegram con argomenti dell'owner (CYRA-852): si collega dal bot, qui si scollega.
  resource :telegram_group, only: :destroy, path: "preferences/telegram/group"
  resource :changelog, only: :show, controller: "changelog"
  resources :organization_switches, path: "switch", only: %i[create]

  # Integrazioni org-level. GitHub App: installazione unica per org (show stato + link install),
  # callback dopo l'installazione su GitHub, disconnessione. Gate organization.manage.
  scope :integrations, as: :integrations do
    resource :github, only: %i[show destroy], controller: "integrations/github" do
      get :callback
    end
  end
  # CYRA-545 — l'elenco dei servizi collegabili con la chiave dell'organizzazione. STA DOPO il
  # blocco qui sopra di proposito: `/member/integrations/github` è la pagina della GitHub App, non
  # un fornitore con una chiave da incollare, e la prima rotta dichiarata vince. Il segmento è il
  # nome del servizio (`param: :provider`) perché una credenziale è una per organizzazione e per
  # servizio: un id nell'indirizzo non aggiungerebbe niente e aprirebbe la porta a chiederne una
  # di un'altra organizzazione. Gate organization.manage, lo stesso della pagina GitHub.
  resources :integrations, only: %i[index update destroy], param: :provider

  # --- Todos personali (per-org, private, condivisibili in sola lettura a membri scelti) ---
  # Dati posseduti dall'utente: nessuna permission key, scoping per ownership. Le voci si
  # spuntano (toggle) e si riordinano (reorder) inline; la condivisione è un singleton per lista.
  resources :todo_lists, path: "lists" do
    patch :reorder, on: :collection
    resource  :sharing, only: %i[show update], module: :todo_lists
    resources :items, only: %i[create update destroy], module: :todo_lists do
      patch :toggle,  on: :member
      patch :reorder, on: :collection
    end
  end
  resources :platforms, except: %i[show]
  resources :environments, except: %i[show]

  # --- RBAC (gestione ruoli + team, gated da permissions.manage) ---
  resources :roles
  resources :teams do
    member { post :access_preview, path: "preview" }   # schema what-if per-membro (owner/god)
  end

  # --- Service account (membri di tipo AI, non-umani, CLI-only) — gated members.manage ---
  # Account kind: :service che accedono via CLI col token cyi_u_ (account-proxy), limitati dall'RBAC
  # (visibilità per-progetto + secrets.read/manage). Namespace `service` (un nome = una parola):
  # Member::Service::AccountsController + tokens nested (reveal-once). Model SEMPRE ::Accounts::* (anti-shadowing).
  namespace :service do
    resources :accounts, only: %i[index new create show update destroy] do
      resources :tokens, only: %i[create destroy], module: :accounts
    end
  end

  # --- Ticketing (Fase D) ---
  resources :groups do
    # Guidance del gruppo (CYRA-75): references + procedures LOCALI del macro-progetto. Controller
    # flat (stesso motivo del progetto). Gate project_groups.manage.
    resource :guidance, only: :show, controller: "group_guidance"
    resources :guidance_references, path: "references", only: %i[new create edit update destroy], controller: "group_guidance_references" do
      patch :reorder, on: :collection
    end
    resources :guidance_procedures, path: "procedures", only: %i[new create edit update destroy], controller: "group_guidance_procedures" do
      patch :reorder, on: :collection
    end
    # Move to another organization (CYRA-879): choose, preview, confirm, follow the status.
    resource :move, only: %i[new create], controller: "project_moves" do
      get :preview
    end
    get "move/status/:move_id", to: "project_moves#show", as: :move_status
  end
  resources :projects do
    # Move to another organization (CYRA-879): choose, preview, confirm, follow the status.
    resource :move, only: %i[new create], controller: "project_moves" do
      get :preview
    end
    get "move/status/:move_id", to: "project_moves#show", as: :move_status
    # `history` (CYRA-827): la cronologia attività del progetto, caricata su richiesta nel riquadro
    # della panoramica e apribile a pagina intera — la via di recupero quando il riquadro non arriva.
    member do
      get :history
    end
    # Credenziali di ingest per-progetto (Fase 1). Controller flat Member::ProjectTokensController:
    # un modulo Member::Projects ombreggerebbe il namespace di dominio ::Projects (model) nei controller Member.
    resources :tokens, only: %i[index create destroy], controller: "project_tokens"
    # Valori personali dei secret (CYRA-79): chi gestisce il vault assegna a una persona un valore
    # diverso dal default, che quella persona riceve con `cyi run`. Path sotto secrets/ ma collezione
    # a sé (non è un secret con un :id): dichiarata PRIMA di `resources :secrets` così "overrides" non
    # può mai essere letto come l'id di un secret. Gate secrets.manage.
    resources :secret_overrides, only: %i[index new create destroy],
              controller: "project_secret_overrides", path: "secrets/overrides"
    # Registro degli accessi ai secret DI QUESTO PROGETTO (CYRA-77): chi ha letto/modificato che
    # cosa, filtrabile per attore, azione, ambiente e periodo. Dichiarata PRIMA di `resources
    # :secrets` per lo stesso motivo di "overrides": il segmento non deve poter essere letto come
    # l'id di un secret. Gate secrets.manage — il registro dice chi legge, non è per chi consuma.
    resources :secret_events, only: :index,
              controller: "project_secret_events", path: "secrets/audit"
    # Vault di variabili d'ambiente cifrate per-progetto/ambiente (tab Secrets, fonte canonica).
    # Controller flat Member::ProjectSecretsController (stesso motivo dei tokens). Gate secrets.read/manage.
    resources :secrets, only: %i[index create destroy], controller: "project_secrets" do
      # Storico versioni + rollback di un secret (versioning, Fase 3). Controller flat.
      resources :versions, only: :index, controller: "project_secret_versions" do
        post :rollback, on: :member
        # Rivela il valore in chiaro di UNA versione storica (CYRA-204): lo storico non rende più i
        # valori nel sorgente. Gate secrets.read, registra l'accesso (audit "read").
        get :reveal, on: :member
      end
      # Copia (promote) del valore di un secret in un altro ambiente ATTIVO del progetto (CYRA-137,
      # dialog di conferma dalla matrice). Upsert via Secrets::Variables::Set: crea o sovrascrive.
      post :promote, on: :member
      # Imposta/rimuove la policy di rotazione "ogni N giorni" (CYRA-138, dialog dalla matrice).
      post :rotation, on: :member
      # Rivela il valore in chiaro di una cella SOLO su richiesta esplicita (CYRA-202): la matrice non
      # rende più i valori nel sorgente. Gate secrets.read, registra l'accesso (audit "read").
      get :reveal, on: :member
    end
    resources :secret_assets, path: "files", only: %i[index new create destroy], controller: "project_secret_assets" do
      get :download, on: :member
      get :versions, on: :member
      post :rollback, on: :member
      delete :purge, on: :member
    end
    # Milestone del progetto (Fase 4). Controller flat Member::ProjectMilestonesController (stesso motivo dei tokens).
    resources :milestones, controller: "project_milestones"
    # Help desk tab: the requests written from this project's sites (CYRA-940). Gate helpdesk.manage.
    resources :helpdesk_requests, path: "helpdesk", only: :index, controller: "project_helpdesk_requests"
    # Documenti del progetto (tab Documents). Controller flat (stesso motivo dei tokens).
    # No new/show: creazione = dropzone nell'index; download = link diretto al blob.
    resources :documents, only: %i[index create edit update destroy], controller: "project_documents"
    # Impostazioni del progetto (tab Settings): override retention log. Controller flat (stesso motivo dei tokens).
    resource :settings, only: %i[show update], controller: "project_settings"
    # Uso del prodotto (tab Uso, CYRA-733): quali funzioni e quali pagine di questo progetto sono
    # state aperte davvero — la rilettura dentro il prodotto di ciò che il canale d'uso (CYSK-29)
    # riceve. `resource` singolare come la guidance: è una lettura sola, senza un :id proprio.
    # Controller flat Member::ProjectUsageController (niente Member::Projects che ombreggia ::Projects).
    resource :usage, only: :show, controller: "project_usage"
    # Guidance del progetto (tab Guidance, CYRA-75): references + procedures LOCALI + preview del
    # contesto effettivo (Guidance::Preview). Controller flat (niente Member::Projects che ombreggia
    # ::Projects, né Member::Guidance che ombreggia ::Guidance). Gate projects.edit.
    resource :guidance, only: :show, controller: "project_guidance"
    resources :guidance_references, path: "references", only: %i[new create edit update destroy], controller: "project_guidance_references" do
      patch :reorder, on: :collection
    end
    resources :guidance_procedures, path: "procedures", only: %i[new create edit update destroy], controller: "project_guidance_procedures" do
      patch :reorder, on: :collection
    end
    # Integrazione GitHub del progetto (tab GitHub): aggancio repo 1:1 + regole binding tag→release.
    # Controller flat Member::ProjectGithubController (stesso motivo dei tokens: niente Member::Github che
    # ombreggerebbe il model ::Github). Gate github.manage.
    resource :github, only: %i[show update destroy], controller: "project_github" do
      post :sync # "Sync now": enfila il push dei secret del vault sui GitHub Environment secrets
    end
    # Tab Environments (CYRA-63): posto unico di gestione degli environment del progetto — tabella con
    # dichiarazione (create/destroy), capability tri-state e multiselect server. Controller flat
    # Member::ProjectEnvironmentsController (stesso motivo dei tokens; niente Member::Projects che
    # ombreggerebbe ::Projects). :id = environment id. Gate projects.edit.
    resources :environments, only: %i[index create destroy], controller: "project_environments"
    # Server collegati per environment (gate uptime.manage). Controller flat Member::ProjectServersController
    # (stesso motivo dei tokens; niente Member::Servers che ombreggerebbe ::Servers). create = sincronizza
    # la lista COMPLETA host_ids[] della coppia [progetto, environment] (multiselect della tab Environments).
    resources :servers, only: :create, controller: "project_servers"
    # Cronologia versioni di una fonte OSSERVATA (Projects::Source) della card Monitoring tools: le
    # versioni viste del tool dalla data di optin a quella di optout. Lettura = visibilità del progetto
    # (nessuna key). Controller flat (niente Member::Projects che ombreggia ::Projects). :source_id =
    # id della Projects::Source. Segmenti a una parola (rules/naming): sources › versions.
    resources :sources, only: [] do
      resources :versions, only: :index, controller: "project_source_versions"
    end
    # Override di capability [servers/uptime/secrets] per ambiente DICHIARATO (tri-state: eredita/on/off).
    # Controller flat Member::ProjectEnvironmentCapabilitiesController (stesso motivo dei tokens).
    # :id = environment id (la riga join Connections::ProjectEnvironment si risolve da [progetto, ambiente]).
    # Gate projects.edit.
    resources :environment_capabilities, path: "capabilities", only: :update, controller: "project_environment_capabilities"
  end

  # --- Alerting (Fase 1): regole (gated da alerts.manage), notification center + preferenze personali ---
  # Controller FLAT (Member::Alerting*Controller): un modulo Member::Alerting ombreggerebbe il
  # namespace di dominio ::Alerting (model) nei controller. Path/helper restano /member/alerting/*.
  scope :alerting, as: :alerting do
    # CYRA-478 — silenziare a tempo è un comando SUO, distinto dallo spegnimento: PUT con `hours`,
    # DELETE per togliere il silenzio prima della scadenza.
    resources :rules, controller: "alerting_rules" do
      # CYRA-482 — applica un modello pronto (può creare la coppia caduta+ritorno in transazione).
      post :apply_template, path: "template", on: :collection
      resource :mute, only: %i[update destroy], module: :alerting_rules
    end
    resources :notifications, only: %i[index destroy], controller: "alerting_notifications" do
      member { patch :read }
      collection do
        patch :read_all, path: "read"
        get :preview
      end
    end
    # Preferenze personali ri-montate sotto /member/preferences/notifications (tab "Notifiche" delle
    # impostazioni account): vedi `resource :notification_preferences` accanto a `resource :preferences`.
    # Canali di consegna esterni (webhook/telegram), agganciati alle regole.
    resources :channels, except: %i[show], controller: "alerting_channels"
  end

  # --- Chat tra membri (Fase chat): DM 1:1 + canali progetto/team, con tagging di risorse comuni ---
  # Controller FLAT (Member::Chat*Controller): un modulo Member::Chat ombreggerebbe il namespace di
  # dominio ::Chat (model) nei controller, come per Alerting. Path/helper restano /member/chat/*.
  scope :chat, as: :chat do
    resources :conversations, only: %i[index show create], controller: "chat_conversations" do
      member { get :taggable } # autocomplete risorse taggabili (intersezione dei partecipanti)
      resource :mute, only: %i[update destroy], controller: "chat_mutes"
      resources :messages, only: %i[create edit update destroy], controller: "chat_messages"
    end
  end

  # Assistente help conversazionale (chat col server AI in streaming). scope :assistant + controller FLAT
  # per non ombreggiare il dominio ::Assistant nei controller (come Chat). Ownership, nessun RBAC.
  scope :assistant, as: :assistant do
    # Corpo del pannello flottante (turbo-frame lazy): conversazione corrente o nuova + composer.
    get "panel", to: "assistant_conversations#panel"
    # CYRA-908 — spoken message; under /conversations so the assistant/ip throttle covers it.
    post "conversations/voice", to: "assistant_voice#create", as: :voice
    # Dictation into a field: same throttle, the text comes back instead of becoming a message.
    post "conversations/dictation", to: "assistant_dictation#create", as: :dictation
    resources :conversations, only: %i[index show create], controller: "assistant_conversations" do
      # show = stato corrente della bolla (fallback di riconciliazione anti-race: se il broadcast
      # finale si perde, il client recupera lo stato finalizzato dal server).
      resources :messages, only: %i[create show], controller: "assistant_messages" do
        # CYRA-907 — confirm every open card of one reply.
        post "proposals/confirm", to: "assistant_proposals#confirm_all", as: :confirm_all_proposals
      end
      resources :proposals, only: %i[update], controller: "assistant_proposals" do
        member do
          post :confirm
          post :discard
          post :restore
        end
      end
    end
  end

  # --- Guides (help in-app: come collegare la propria app) ---
  # CYRA-357 — il punto d'ingresso unico per annotare qualcosa: chiede COSA si sta scrivendo e
  # instrada al form giusto. Le scorciatoie dirette dalle sezioni restano.
  get "new", to: "quick_add#show", as: :quick_add

  get "guides/installation", to: "guides/installation#show", as: :guides_installation
  get "guides/installation/receipt", to: "guides/installation#receipt", as: :guides_installation_receipt
  get "guides",             to: "guides#index",       as: :guides
  get "guides/overview",    to: "guides#overview",    as: :guides_overview
  get "guides/ticket-lifecycle", to: "guides#ticket_lifecycle", as: :guides_ticket_lifecycle
  get "guides/errors",      to: "guides#errors",      as: :guides_errors
  # CYRA-782 — le domande di primo livello sui ticket: dove si chiede, dove si risponde e cosa
  # significa una domanda che ferma il lavoro.
  get "guides/questions",   to: "guides#questions",   as: :guides_questions
  get "guides/assistant",   to: "guides#assistant",   as: :guides_assistant
  get "guides/helpdesk",    to: "guides#helpdesk",    as: :guides_helpdesk
  get "guides/uptime",      to: "guides#uptime",      as: :guides_uptime
  get "guides/performance", to: "guides#performance", as: :guides_performance
  get "guides/logs",        to: "guides#logs",        as: :guides_logs
  # CYRA-376 — la registrazione delle sessioni non era nominata da nessuna guida: si scopriva
  # scrivendo l'indirizzo a mano, e non c'era scritto da nessuna parte come accenderla.
  get "guides/replays",     to: "guides#replays",     as: :guides_replays
  # CYRA-485 — i lavori programmati non avevano una guida: fra tredici, nessuna li nominava.
  get "guides/crons",       to: "guides#crons",       as: :guides_crons
  get "guides/servers",     to: "guides#servers",     as: :guides_servers
  get "guides/analytics",   to: "guides#analytics",   as: :guides_analytics
  get "guides/secrets",     to: "guides#secrets",     as: :guides_secrets
  get "guides/secret-overrides", to: "guides#secret_overrides", as: :guides_secret_overrides
  get "guides/shared-values", to: "guides#shared_values", as: :guides_shared_values
  get "guides/knowledge",   to: "guides#knowledge",   as: :guides_knowledge
  get "guides/knowledge-review", to: "guides#knowledge_review", as: :guides_knowledge_review
  get "guides/traces", to: "guides#traces", as: :guides_traces
  get "guides/measurements", to: "guides#measurements", as: :guides_measurements
  get "guides/session-health", to: "guides#session_health", as: :guides_session_health
  get "guides/tickets",     to: "guides#tickets",     as: :guides_tickets
  get "guides/vault",       to: "guides#vault",       as: :guides_vault
  get "guides/feature-matrix", to: "guides#feature_matrix", as: :guides_feature_matrix
  get "guides/approvals",   to: "guides#approvals",   as: :guides_approvals
  # CYRA-630 — la guida delle lavorazioni in volo non c'è più: quell'elenco è diventato il secondo
  # della pagina delle decisioni, e a spiegarlo è la guida delle approvazioni. Il rimando resta per
  # la voce di CHANGELOG che la cita, che è già pubblicata e non si riscrive.
  get "guides/workflows", to: redirect("/member/guides/approvals")
  get "guides/guidance",    to: "guides#guidance",    as: :guides_guidance
  get "guides/vulnerabilities", to: "guides#vulnerabilities", as: :guides_vulnerabilities
  get "guides/seo",             to: "guides#seo",             as: :guides_seo
  get "guides/permissions", to: "guides#permissions", as: :guides_permissions
  # CYRA-745 — cosa risponde il registro attività, e cosa NON ci si trova (i registri personali).
  get "guides/activity",    to: "guides#activity",    as: :guides_activity
  # CYRA-441 — i contenitori dentro cui vive tutto il resto (organizzazione, gruppi, progetti,
  # ambienti, piattaforme): erano più di dieci concetti che si incrociano, spiegati in nessun posto.
  get "guides/structure",   to: "guides#structure",   as: :guides_structure
  # CYRA-454 — i Dataset: cos'è una scelta che si può insegnare, e cosa NON è.
  get "guides/datasets",    to: "guides#datasets",    as: :guides_datasets
  # CYRA-545 — i servizi esterni collegati con la chiave dell'organizzazione: cos'è una chiave,
  # dove si prende, perché non si rilegge più e cosa si spegne togliendola.
  get "guides/integrations", to: "guides#integrations", as: :guides_integrations
  # CYRA-501 — le macchine che lavorano i ticket (il ciclo, gli esiti, l'attesa di una risposta) e
  # la versione delle competenze che eseguono: la parte da cui dipende il valore del prodotto era
  # l'unica senza una riga di spiegazione.
  get "guides/agents",      to: "guides#agents",      as: :guides_agents
  # CYRA-593 — l'elenco di tutte le lavorazioni in volo: cosa ci si trova dentro, i tre stati e
  # dove si decide. La differenza fra «aspetta una persona» e «va avanti da sola» è la cosa che
  # nessuno indovina guardando una tabella.
  get "guides/skill-bundles", to: "guides#skill_bundles", as: :guides_skill_bundles
  # CYRA-160 — il riepilogo periodico dei dati via email: quando arriva, cosa contiene e perché
  # non è la stessa cosa degli avvisi.
  get "guides/reports",     to: "guides#reports",     as: :guides_reports
  # CYRA-879 — moving a project or group to another organization.
  get "guides/project-moves", to: "guides#project_moves", as: :guides_project_moves

  # --- Richieste AI asincrone (la UI polla l'esito dopo il 202 degli endpoint AI) ---
  namespace :ai do
    resources :requests, only: :show
  end

  # --- Error monitoring (Fase 2) ---
  namespace :monitoring do
    resources :measurement_rules, path: "measurements/alerts"
    resources :measurements, only: %i[index show]
    resources :traces, only: %i[index show]
    get "sessions", to: "session_health#index", as: :session_health
    # CYRA-483 — la pagina di stato pubblica ha una sua voce di menu: era la funzionalità di maggior
    # valore dell'area e la si scopriva solo leggendo una guida che nessuna pagina richiamava, senza
    # indirizzo visibile né anteprima.
    resource :status_page, path: "status", only: :show, controller: "status_pages"
    # --- Web analytics (dashboard pageview cookieless, un progetto per volta) ---
    resource :analytics, only: :show, controller: "analytics"
    # Goals/conversioni del progetto (project_id come query param, come la dashboard).
    namespace :analytics do
      resources :goals, only: %i[index new create destroy]
      # Link pubblico di condivisione/embed (uno per progetto): crea / revoca.
      resource :share, only: %i[create destroy], controller: "shares"
    end

    # CYRA-800 — smistamento e fusione hanno un controller ciascuno, ma gli INDIRIZZI restano quelli
    # di sempre: `to:` cambia solo chi risponde, non il percorso né il nome dell'helper. Presidio:
    # spec/config/error_groups_controller_split_spec.rb.
    resources :error_groups, path: "error", only: %i[index show destroy] do
      # CYRA-45: smistamento a più gruppi dalla lista (resolve/ignore/reopen su N selezionati).
      # Anti-BOLA + gate errors.triage per progetto nel controller.
      collection do
        post :bulk_triage, path: "triage", to: "error_groups/triages#bulk_triage"
        # CYRA-192: la fusione in due passi. `merge_preview` è POST e non GET perché i gruppi
        # arrivano dai checkbox della lista (ids[]), che possono essere molti: un GET li metterebbe
        # in query string. La conferma è una PAGINA e non un dialog: deve mostrare titoli, punto del
        # codice e conteggi di ciò che sparisce, e farsi scegliere il primario — su un'operazione
        # che non si annulla, «sei sicuro?» non è abbastanza.
        post :merge_preview, path: "merge/preview", to: "error_groups/merges#preview"
        post :merge, to: "error_groups/merges#create"
      end
      member do
        patch :resolve, to: "error_groups/triages#resolve"
        patch :ignore,  to: "error_groups/triages#ignore"
        patch :reopen,  to: "error_groups/triages#reopen"
        post  :promote
        # CYRA-153: assegna/disassegna l'errore a una persona (assignee_id nel body, vuoto = disassegna).
        patch :assign
        # Verdetto AI on-demand (draft non persistito): verdetto strutturato + cluster errori simili.
        post  :triage_ai, path: "analyze", to: "error_groups/triages#triage_ai"
        post  :similar
        # Pagine Knowledge semanticamente correlate al gruppo (pannello lazy nella show).
        post  :knowledge
        # Session replay dell'occorrenza (rrweb events uniti, JSON) per il player nella show.
        get   :replay
      end
    end

    # --- Uptime monitoring (Fase 3) ---
    resources :monitors do
      member do
        patch :pause
        patch :resume
        # Status page pubblica (opt-in): pubblica/ritira la pagina /status/... del monitor.
        patch :publish
        patch :unpublish
      end

      # Incident narrati: unificazione (grouping) + timeline a step (updates). Gate uptime.manage.
      scope module: :incidents do
        # bulk: unifica gli incident selezionati e posta il primo step (incident_ids[], phase, body)
        post "incidents/group", to: "groups#create", as: :incidents_group
        # destroy = elimina l'intero incident (+ finestre unificate figlie, cascade nel service).
        resources :incidents, only: %i[destroy] do
          resource :group, only: %i[destroy]           # DELETE .../incidents/:incident_id/group — scioglie il raggruppamento
          resources :updates, only: %i[create destroy]  # step successivi della timeline
        end
      end

      # Banner status page pubblica (manutenzioni/avvisi): uno per monitor.
      resource :announcement, only: %i[create update destroy], module: :monitors
    end

    # Tab Incidents di Monitor › Uptime: feed cross-monitor paginato + filtro stato (aperti/risolti).
    # Top-level (NON la resources :incidents nested in monitors, che è destroy/timeline per-monitor).
    resources :incidents, only: %i[index]

    # Gruppi di monitor uptime (contenitori org-level). CRUD gated uptime_groups.view/manage.
    # publish/unpublish = status page pubblica per-gruppo (opt-in).
    resources :uptime_groups, path: "groups" do
      member do
        patch :publish
        patch :unpublish
      end
    end

    # --- Performance monitoring (gruppi-metrica: query/metodi lenti + verdetti performance_issue) ---
    resources :metric_groups, path: "performance", only: %i[index show] do
      # CYRA-45: triage bulk dalla lista (resolve/ignore/reopen su N gruppi selezionati). Anti-BOLA +
      # gate metrics.promote per progetto nel controller.
      collection { post :bulk_triage, path: "triage" }
      member do
        post :promote
        # Triage AI on-demand (draft non persistito): verdetto strutturato performance.
        post :triage_ai, path: "analyze"
      end
    end

    # --- Cron / heartbeat monitoring ---
    # CYRA-484 — i lavori programmati erano in SOLA lettura: nascevano al primo check-in e da lì
    # nessuno poteva più correggerne il nome, allungarne la tolleranza o metterli in pausa durante
    # una manutenzione. Ora hanno le stesse azioni dei monitor uptime (gate uptime.manage sul
    # progetto). La creazione resta al primo check-in: un lavoro esiste perché batte, non perché
    # qualcuno lo ha dichiarato.
    resources :cron_monitors, path: "cron", only: %i[index show edit update destroy] do
      resource :pause, only: %i[update destroy], module: :cron_monitors # PUT sospendi / DELETE riprendi
      # CYRA-485 — le istruzioni per mettere sotto controllo un lavoro: non essendoci una creazione
      # dall'interfaccia (il monitor nasce al primo check-in), è QUESTA la pagina di partenza.
      collection { get :setup }
    end

    # --- Logs (stream strutturato cross-app) ---
    resources :log_entries, path: "logs", only: %i[index show] do
      # Collegamenti manuali log↔errore/ticket (gate logs.link).
      resources :links, only: %i[create destroy], module: :log_entries
      # CYRA-347 — apre un ticket già compilato da QUESTO messaggio, come si fa da un rallentamento.
      # Singolare: il messaggio ha una sola promozione. Gate logs.link (è un collegamento che nasce).
      resource :promotion, only: :create, module: :log_entries
    end

    # --- Session replay (galleria sessioni registrate + viewer) ---
    resources :replays, only: %i[index show] do
      member { get :player } # eventi rrweb uniti (JSON) per il player standalone
    end

    # --- Vulnerabilità delle dipendenze (CYRA-506): lockfile dei repository × OSV.dev ---
    # `runtimes` è una tab della stessa sezione (versioni di linguaggio fuori supporto), non una
    # risorsa a sé: vive come collection perché condivide header, filtri e permessi con l'elenco.
    resources :vulnerabilities, only: %i[index show] do
      member do
        patch :ignore   # convivo col rischio (richiede vulnerabilities.triage)
        patch :reopen   # ci ripenso
        post :promote   # apri un ticket a mano (l'automatico scatta solo su high/critical)
      end
      collection do
        get :runtimes
        post :rescan    # scansione su richiesta, senza aspettare il giro notturno
      end
    end

    # --- Cockpit SEO (CYRA-528): i siti dichiarati, visitati a intervalli ---
    # Stessa forma delle vulnerabilità: elenco cross-progetto dei rilievi (project_id è un filtro,
    # non un segmento) e `pages` come scheda della stessa sezione. I siti sono una risorsa a sé
    # perché sono configurazione, con un form proprio e un permesso diverso dal triage.
    resources :seo, only: %i[index show], controller: "seo" do
      member do
        patch :ignore   # ci convivo (richiede seo.triage)
        patch :reopen   # ci ripenso
        post :promote   # apri un ticket dal rilievo
      end
      collection do
        get :pages      # le pagine viste, con il loro stato
        post :rescan    # visita su richiesta (richiede seo.manage)
      end
    end
    # CYRA-536 — la `show` è la scheda del sito: prima la riga dell'elenco portava fuori
    # dall'applicazione, sul sito stesso. `issues` e `pages` sono le sue schede, non due pagine
    # nuove: gli stessi elenchi dell'area, ristretti a questo sito.
    resources :seo_sites, path: "sites", only: %i[index show new create edit update destroy] do
      member do
        get :issues
        get :pages
        get :performance
      end
    end

    # --- Server monitoring (flotta org-scoped, dati push-ati da closeyourit-agent) ---
    resources :servers, only: %i[index show edit update destroy] do
      member do
        patch :pause
        patch :resume
        # Revoca = l'agent riceve 403 e si ferma (l'host resta, niente re-registrazione fantasma);
        # destroy = eliminazione dati (da fare DOPO aver spento l'agent).
        patch :revoke
        patch :unrevoke
        # CYRA-245 — riadozione: autorizza UNA sonda reinstallata a prendere il posto di quella
        # registrata su questa macchina. Senza, una credenziale viva non si sostituisce mai.
        patch :reenroll
      end
      resources :actions, only: %i[create destroy], controller: "server_actions"
      # CYRA-519 — silenzia una regola di avviso SU QUESTA macchina (POST) o la riattiva (DELETE).
      # Vive sotto la macchina perché è dalla sua scheda che si mette e si toglie: un silenzio che
      # non si vede è un silenzio dimenticato. Gate alerts.manage.
      resources :alert_exclusions, path: "exclusions", only: %i[create destroy], module: :servers, param: :rule_id
      # Inventario database del singolo host (tab della sua pagina). Segmento a una parola,
      # controller flat prefissato come le altre sotto-risorse del server.
      # `id` = nome del database (chiave naturale, non un record): il constraint accetta i punti,
      # che Rails leggerebbe altrimenti come estensione di formato.
      resources :databases, only: %i[index show], controller: "server_databases",
                constraints: { id: %r{[^/]+} }
    end
    # Enrollment token della flotta (universale org-scoped, reveal-once).
    resources :server_tokens, path: "tokens", only: %i[index create destroy]
    # Inventario database di TUTTA la flotta (stessa tabella, tutti gli host con un database).
    resources :databases, only: %i[index]
    # Kubernetes clusters watched by closeyourit-kube (CYAG-22).
    resources :clusters, only: %i[index show new create update destroy] do
      member do
        patch :rotate
      end
      resources :nodes, only: :index, controller: "cluster_nodes"
      resources :workloads, only: :index, controller: "cluster_workloads"
      resources :problems, only: :index, controller: "cluster_problems"
      resources :namespaces, only: :update, controller: "cluster_namespaces"
    end
  end
  resources :tickets do
    resource :automation, only: :show, module: :tickets do
      resource :plan, only: :show, module: :automation
      resource :approval, only: :create, module: :automation
      resource :change_request, path: "changes", only: :create, module: :automation
      resource :cancellation, only: :create, module: :automation
      # Riprova una lavorazione ferma per tetto di revisione (CYRA-218): è l'unica uscita quando la
      # fase bocciata non ha prodotto un piano, e approvazione/modifiche non hanno su cosa lavorare.
      resource :unblock, only: :create, module: :automation
      # CYRA-675 — «serve ancora, o e' gia' fatto?». Rimanda alla pianificazione, che rilegge il
      # codice di oggi: gemello del pulsante della home, stessa decisione presa da un'altra pagina.
      resource :reassessment, only: :create, module: :automation
      # CYRA-624 — «segna come rilasciato»: per quando sai tu che il rilascio è a posto e la
      # macchina non riesce a vederlo. Resta scritto chi l'ha premuto e quando.
      resource :release_mark, path: "released", only: :create, module: :automation
      # CYRA-871 — «Ferma» un rilascio prima della produzione: tiene occupata la fila del repository.
      resource :production_hold, path: "hold", only: :create, module: :automation
    end
    # Resoconto di lavorazione (CYRA-265), sola LETTURA: il corrente vive nella scheda `?tab=report`
    # della show, qui c'è solo la cronologia delle stesure. Specchio delle rotte CLI, meno il POST —
    # dal web il resoconto non si scrive: lo scrivono la CLI e la migrazione dei commenti storici.
    resources :report_versions, only: :show, module: :tickets, path: "report/versions", param: :version
    collection do
      # Board Kanban = index (default). La tabella filtrabile vive su #list ("list view").
      get :list
      # «Mostra altre» di una colonna della board (CYRA-390): append incrementale via Turbo Stream
      # del blocco successivo di card (?status_id=&page=). Senza Turbo ripiega sulla vista lista.
      get :column
      # Colonne ridotte della board (CYRA-390): preferenza personale per code di status. POST
      # collassa, DELETE espande. Vedi Member::Tickets::CollapsedColumnsController.
      resources :collapsed_columns, path: "columns", only: %i[create destroy], module: :tickets, param: :code
      # Assistente AI bug-report rapido (draft non persistito): analizza il testo libero e ritorna
      # i 4 campi Given/When/Then/Expected o domande di chiarimento. Gated dal flag di progetto.
      post :analyze
      # AI Buddy (draft non persistito): dal testo libero l'AI compone l'intero ticket
      # (titolo/tipo/descrizione + clausole GWT per i bug). Async come #analyze.
      post :compose
      # Suggerimento duplicati (draft non persistito): embed del testo → top-k ticket simili
      # tra quelli visibili all'account. Il create NON dipende mai da questo endpoint.
      post :duplicates
      # RAG "chiedi ai ticket": pagina (GET) + domanda in NL (POST JSON) sui ticket visibili.
      get :ask
      post :ask, action: :ask_query, as: nil
      # Voci del campo «Ticket collegato» (CYRA-364): poche righe cercate lato server per codice
      # o titolo, invece dell'intero archivio caricato con la pagina.
      get :linkable, to: "tickets/linkable#index"
    end
    member do
      patch :status
      patch :assignee
      patch :reviewer
      # Pagine Knowledge semanticamente correlate al ticket (pannello lazy nella show).
      post  :knowledge
    end
    # Discussione + allegati (Fase D bis). Controller Member::Tickets::*.
    resources :comments, only: %i[create destroy], module: :tickets
    resources :attachments, only: %i[create destroy], module: :tickets
    # Domande e risposte di primo livello (CYRA-782). Chiedere e rispondere sono baseline di chi vede
    # il ticket: è una conversazione. Marcare una domanda bloccante ferma la coda degli agenti, quindi
    # è una leva sul lavoro e passa da tickets.edit — come il ritiro di una domanda altrui.
    resources :questions, only: %i[create destroy], module: :tickets do
      resources :answers, only: :create, module: :questions
      resource :closure, only: :update, module: :questions
    end
    # CYAU-235 — a person marks a decision the supporter took alone as seen; it leaves "To review".
    resources :supporter_decisions, path: "decisions", only: [], module: :tickets do
      patch :seen, on: :member
    end
    # Collegamenti ticket↔ticket del gate duplicati: nascono SOLO dal flusso di confronto
    # (Ticketing::ResolveDuplicate); qui la sola rimozione (gate tickets.edit).
    resources :links, only: :destroy, module: :tickets
    # Dipendenze (prerequisiti) tra ticket (CYRA-82): POST aggiunge / DELETE rimuove. Gate tickets.edit.
    resources :dependencies, only: %i[create destroy], module: :tickets
    # Voto (upvote) singleton: identità = ticket parent, PUT/DELETE idempotenti.
    resource :vote, only: %i[update destroy], module: :tickets
    # Watch (sottoscrizione) singleton: PUT iscrive / DELETE disiscrive (idempotenti), come il voto.
    resource :watch, only: %i[update destroy], module: :tickets
    # Presa in carico a termine (CYRA-295): stesso lease server-side di agenti e CLI, titolare
    # account. POST prende / DELETE rilascia. Gate tickets.assign.
    resource :lease, only: %i[create destroy], module: :tickets
    # Eleggibilità agenti (CYRA-184): override umano del verdetto automatico. Singleton come
    # status/reviewer, e NON un campo del form: così un POST della modifica ticket non può alzare
    # il gate di sicurezza. Gate tickets.edit.
    resource :eligibility, only: :update, module: :tickets
    # Integrazione GitHub del ticket (Fase 2): crea branch / apre PR dal ticket (identità bot App).
    # Controller Member::Tickets::GithubController, gate github.manage.
    resource :github, only: [], module: :tickets, controller: "github" do
      post :branch
      post :pull_request, path: "pr"
    end
    # Decisioni di review (solo su status review-gate): rejection col motivo, approval secca.
    # Segmenti una-parola (rules/naming.md) → POST /member/tickets/:ticket_id/review/{rejection,approval}.
    scope module: :tickets do
      namespace :review do
        resource :rejection, only: :create
        resource :approval, only: :create
      end
    end
  end
  # Idee di progetto: proposte votabili/commentabili, promuovibili a ticket (sintesi AI della
  # discussione + preview editabile). Vedere/creare/votare/commentare = baseline dello scope;
  # gestione idee altrui gated (ideas.*). Controller Member::Ideas::*.
  resources :ideas do
    collection do
      # Idee simili (bozza non persistita): embed del testo → top-k idee simili tra quelle
      # visibili. La proposta NON dipende mai da questo endpoint (CYRA-167).
      post :duplicates
    end
    member do
      patch :archive
      patch :reopen
    end
    resources :comments, only: %i[create destroy], module: :ideas
    # Case (esempi/scenari): contenuto figlio dell'idea, aggiunto una alla volta sulla show.
    resources :cases, only: %i[create update destroy], module: :ideas
    # CYRA-845 — collegamenti fra idee (parenti alla pari); :id in destroy = l'ALTRA idea.
    resources :links, only: %i[create destroy], module: :ideas
    # Voto (upvote) singleton: identità = idea parent, PUT/DELETE idempotenti (come i ticket).
    resource :vote, only: %i[update destroy], module: :ideas
    # Sintesi AI idea+commenti → bozza ticket: accoda Ai::Request (202), la UI polla ai/requests.
    resource :synthesis, only: :create, module: :ideas
    # Conversione in ticket: new = preview editabile (prefill AI), create = Ideas::PromoteToTicket.
    resource :conversion, only: %i[new create], module: :ideas
  end
  # Help desk: what the visitors of the projects' sites wrote (CYRA-940). Flat controller names: a
  # Member::Helpdesk module would shadow the ::Helpdesk models.
  resources :helpdesk_requests, only: %i[index show], path: "helpdesk" do
    resource :discard, only: %i[update destroy], module: :helpdesk_requests # PUT discard / DELETE restore
    resource :email, only: :destroy, module: :helpdesk_requests             # erase the visitor's address
    # CYRA-941 — new = editable ticket draft, create = Helpdesk::PromoteToTicket.
    resource :conversion, only: %i[new create], module: :helpdesk_requests
    resource :ticket_link, path: "link", only: %i[create destroy], module: :helpdesk_requests # join a ticket / undo
    resource :reply, only: :create, module: :helpdesk_requests                  # answer the visitor by email (CYRA-943)
  end
  # Knowledge base di progetto: pagine markdown (note/decisioni/guide) con ricerca semantica
  # cross-progetto sui progetti visibili. Controller Member::Knowledge::*.
  namespace :knowledge do
    # Pagina d'ingresso dell'area (CYRA-415): un indice che insegna il percorso — Revisione,
    # Conoscenza, Book, nell'ordine d'uso reale — con definizione, contatore e azione per voce.
    root to: "overview#show"
    resources :pages do
      collection do
        # RAG "chiedi alla KB": pagina (GET) + domanda in NL (POST JSON) sulle pagine visibili.
        get :ask
        post :ask, action: :ask_query, as: nil
        # Titoli suggeriti mentre si apre un wikilink `[[…]]` nel corpo (CYRA-433): JSON, ristretto
        # alle pagine visibili a chi scrive.
        get :link_suggestions, path: "suggestions"
      end
      # Cronologia versioni (sola lettura) + ripristino di una versione come nuova live.
      resources :versions, only: %i[index show] do
        member { post :restore }
      end

      # File allegati alla pagina (anche script, inerti). Niente :index — l'elenco è una card
      # della show; niente :new/:show — si carica dalla dropzone e si scarica dal download.
      # Il download passa da qui e MAI da rails_blob_path: il path non contiene il filename (che
      # farebbe intercettare un `install.php` da rack-attack) e il Content-Type è forzato binario.
      resources :attachments, only: %i[create edit update destroy] do
        member { get :download }
      end
    end
    # Book = collezioni ordinate di pagine (vista Outline). La pagina attiva nella show è un
    # query param (?page_id=…), non un segmento: nessuna route nested necessaria.
    resources :books
    # Coda di revisione (CYRA-298): le pagine proposte da un assistente, in attesa che un umano
    # le accetti o le scarti. Solo index + le due decisioni: la lettura della proposta avviene
    # nella riga stessa, quindi non serve una show.
    resources :reviews, only: :index do
      member do
        post :approve
        post :reject
        # CYRA-768 — «è ancora vera»: fa ripartire il conto della rilettura senza toccare il testo.
        # Bersaglia una pagina PUBBLICATA, non una proposta, ma vive qui perché è la stessa coda e
        # lo stesso gesto — rileggere quello che l'archivio afferma.
        post :confirm
      end
    end
  end
  # Matrice funzionalità × piattaforme (CYRA-256): una per macro-progetto. L'index elenca i
  # prodotti, la show è la matrice del prodotto (:id = Projects::Group). Controller
  # Member::Product::* → i model vanno SEMPRE fully-qualified (::Product::Feature), altrimenti
  # Product::Feature risolve dentro il namespace del controller e alza NameError a runtime.
  namespace :product do
    resources :matrices, only: %i[index show], path: "matrix"
    resources :categories, only: %i[new create edit update destroy]
    resources :features, only: %i[new create edit update destroy] do
      # Cella: l'identità è [funzionalità, piattaforma], quindi la piattaforma È il parametro
      # (nessun id proprio nell'URL). Niente :index/:show — la cella si vede nella matrice.
      # new/create servono a segnare una funzionalità su una piattaforma che non è ancora una
      # colonna (es. iOS prima che esista il progetto iOS): lì la piattaforma la sceglie il form.
      resources :cells, only: %i[new create edit update destroy], param: :platform_id, module: :features
    end
  end
  # Board del carico di lavoro non-dev, team-scoped: una action appartiene a un team e la
  # vede/gestisce solo chi ne è membro (auth = appartenenza al team, nessun permesso RBAC).
  # Controller Member::Workload::ActionsController (+ Actions::PromotionsController per "genera ticket").
  # CYRA-372 — `/member/workload` è l'indirizzo che si indovina da soli (il menu punta alla
  # sotto-rotta): portava a un errore. Ora apre la board, che è la vista principale.
  get "workload", to: redirect("/member/workload/actions")
  namespace :workload do
    resources :actions do
      collection do
        # Board Kanban per status = index (default). La tabella filtrabile vive su #list ("list view").
        get :list
      end
      member do
        # Drag della board = cambio status (enum). Scoping team-membership anti-BOLA (404), no RBAC.
        patch :status
      end
      resource :promotion, only: %i[new create], module: :actions
    end
  end
  # Sezione AI — Dataset: colonne dinamiche + foto + colonna result → prompt ottimizzato per predire
  # il result. Per-progetto (lettura = progetti visibili, anti-BOLA; gestione gated datasets.manage).
  # Controller flat Member::DatasetsController; sub-risorse Member::Datasets::* (righe/training/
  # predizioni) aggiunte nelle fasi successive.
  resources :datasets do
    # Righe di dati (valori scalari + celle foto). Controller Member::Datasets::RowsController.
    resources :rows, only: %i[new create edit update destroy], module: :datasets
    # Training: genera il prompt ottimizzato (loop). create accoda Datasets::TrainJob; show polla lo stato.
    resources :trainings, only: %i[show create], module: :datasets
    # Inferenza: applica il prompt a una foto/riga nuova. create accoda Datasets::PredictJob; show polla.
    resources :predictions, only: %i[new create show], module: :datasets
  end
  # Sezione AI — Agents (host-first, CYAU-88): /member/agents elenca gli HOST (i Mac) e la loro
  # attività (heartbeat online/offline, run attive, lease, attempt). Un host reclama la prossima fase
  # pronta di un ticket ed esegue la skill di quella fase. Lettura = agents.view; certificazione
  # (via libera umano all'esecuzione) = agents.manage. Qui "agent" significa host: i typed agent non
  # esistono più, né come rotta né come tabella (CYAU-85).
  # Token org dell'automator (cyi_a_): pagina di emissione/revoca reveal-once. Dichiarata PRIMA di
  # resources :agents così /member/agents/tokens non finisce catturato da agents#show (:id="tokens").
  namespace :agents do
    resources :tokens, only: %i[index create destroy]
    # CYAU-224 — the Claude credential lent to the machines (owner only, write-only).
    resource :claude_credential, path: "claude", only: %i[show update destroy]
    # CYAU-227 — who works and who reviews for every machine without a choice of its own.
    resource :automator_setting, path: "automator", only: %i[show update]
    # CYAU-228 — the OpenRouter key OpenCode reviews with (owner only, write-only).
    resource :openrouter_credential, path: "openrouter", only: %i[show update destroy]
  end
  # CYRA-516 — `destroy` elimina la macchina DISMESSA e con lei il suo storico: senza, un Mac buttato
  # via resta in elenco per sempre (la revoca stacca le credenziali ma non toglie la riga).
  resources :agents, only: %i[index show destroy] do
    collection do
      get :compare    # CYRA-451 — due host affiancati sullo stesso periodo
    end
    member do
      post :certify     # B.1b — via libera umano all'esecuzione (setta certified_at/by)
      post :decertify   # revoca la certificazione (torna ineleggibile)
      patch :review     # CYRA-921 — chi rilegge il lavoro: l'altro motore o lo stesso
      patch :engine     # CYRA-921 — who does the work: Claude or Codex
      patch :follow_organization, path: "follow" # CYAU-227 — drop the machine's own choice, follow the organization's
    end
    # CYRA-1052 — this machine's own Claude credential (owner only, write-only).
    resource :claude_credential, path: "claude", controller: "agents/host_claude_credentials", only: %i[update destroy]
  end
  # CYRA-593 — l'elenco di TUTTE le lavorazioni in volo, comprese quelle che l'agente sta ancora
  # facendo e che non chiedono niente a nessuno. CYRA-630 le ha riportate dentro le decisioni, come
  # secondo elenco: la pagina non esiste più. Il rimando resta, e non è cortesia — l'indirizzo è nei
  # preferiti di chi lo usava ogni giorno, ed è citato da una voce di CHANGELOG già pubblicata, che
  # non si riscrive. Un 404 è il modo peggiore di dire che una cosa si è spostata.
  get "workflows", to: redirect(path: "/member/home/approvals", params: { view: "in_flight" })

  # Skill bundle pinnato (singleton per org, B.2): pin dei 4 valori repo/ref/version/digest. Vetrina + override manuale.
  resource :skill_bundle, path: "skills", only: %i[show update]
  # Viste salvate delle index filtrabili (filtri nominati, personali, per risorsa). Applicare = GET
  # all'index coi param. resource_type nel payload discrimina la risorsa (tickets, error_groups, …).
  resources :saved_views, path: "views", only: %i[create destroy]
end

# Indirizzo esplicito dell'area iniziale (space Home, CYRA-328). Le verticali hanno un'overview nominata
# /member/<id>; la Home vive su "/" ma il suo indirizzo /member/home deve rispondere invece di dare 404,
# così deep-link e switcher atterrano sulla dashboard. Rende lo stesso HomeController della root (fuori dal
# namespace member: la Home non è Member::HomeController).
get "member/home", to: "home#index", as: :member_home

# CYRA-554 — accorciare l'indirizzo fino alla radice dell'area non è un errore di digitazione: è il
# gesto con cui si torna indietro. `/member` non è mai stato un indirizzo (la Home vive su "/") e
# finiva nel catch-all globale, cioè su "questa pagina non esiste". Ora riporta dove ci si aspetta.
get "member", to: redirect("/")

# Old multi-word addresses (before the single-word rename) still arrive from links already sent:
# they redirect to the new address instead of reaching the not-found page below.
get "member/*path", to: redirect(::Routing::LegacyPaths), constraints: ::Routing::LegacyPaths, format: false

# Indirizzi inesistenti dell'area (CYRA-462): catch-all DOPO ogni rotta member reale (namespace +
# /member/home) → priorità minima, cattura solo ciò che nessuna rotta ha già servito e rende la 404 di
# prodotto (guscio member, lingua dell'utente, via d'uscita) invece della statica grezza di Rails. Solo
# GET: è la navigazione a un URL sbagliato (caso osservato: /member/monitoring/server_databases).
# `format: false` per catturare anche i path con punti senza leggerli come estensione di formato.
get "member/*path", to: "member/errors#not_found", format: false
