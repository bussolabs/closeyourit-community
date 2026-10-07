# Riga di comando (cyi): device-flow di accesso e tutte le operazioni sotto /cli/*, a token utente.

# --- CLI (token utente, device-flow) — tutto sotto /cli/* (modulo Cli::). Vedi CLAUDE.md. ---
namespace :cli do
  # Bootstrap device-flow (RFC 8628) — NON autenticato.
  post "device/authorize", to: "device#authorize"
  post "device/token",     to: "device#token"

  # Approvazione browser del device-flow (umano loggato).
  get  "authorize",                    to: "authorizations#show",    as: :authorize
  post "authorize/:user_code/approve", to: "authorizations#approve", as: :authorize_approve
  post "authorize/:user_code/deny",    to: "authorizations#deny",    as: :authorize_deny

  # API dati (bearer token utente). Override voluto di rules/rails/api.md (API normalmente /api/v1).
  namespace :v1 do
    get "whoami", to: "whoami#show"

    # I PROPRI token CLI (CYRA-643): elenco cross-org e revoca, per chiudere un dispositivo perso
    # senza aprire il browser. `:id` accetta anche la parola "current" = il token con cui si sta
    # chiamando (`cyi logout --revoke`). Controller flat Cli::V1::UserTokensController: un
    # Cli::V1::Auth ombreggerebbe ::Auth, il namespace dell'autenticazione web.
    resources :user_tokens, path: "auth/tokens", only: %i[index destroy], controller: "user_tokens"

    namespace :types do
      resources :environments,      only: :index
      resources :platforms,         only: :index
      resources :ticket_statuses,   only: :index
      resources :ticket_priorities, only: :index
      resources :feature_statuses,  only: :index # stati di una cella della matrice prodotto
    end

    # Matrice funzionalità × piattaforme (CYRA-256) dal terminale. Il prodotto (Projects::Group) è
    # SEMPRE nel path: dentro un prodotto il nome di una categoria è unico, quindi "Categoria/Nome"
    # identifica una funzionalità senza ambiguità — cosa che fuori dal prodotto non varrebbe.
    # La cella non ha id proprio (la piattaforma È il parametro, come nel canale Member): PUT è un
    # upsert su [funzionalità, piattaforma], DELETE azzera. Gate product_features.view/manage.
    namespace :product do
      resources :matrices, only: %i[index show], path: "matrix" do
        resources :categories, only: %i[index create update destroy]
        resources :features,   only: %i[index show create update destroy] do
          resources :cells, only: %i[update destroy], param: :platform_id, module: :features
        end
      end
    end

    resources :groups, only: %i[index show create update destroy] # macro-progetti (contenitori di progetti)
    # File segreti CONDIVISI org-level da terminale (CYRA-641): stesso ciclo di vita dei file di
    # progetto — storico, ripristino e cancellazione definitiva — piu' le deleghe, che esistono solo
    # qui (un file personale non si delega a nessuno).
    resources :shared_secret_assets, only: %i[index create destroy] do
      member do
        get :download
        get :versions
        post :rollback
        delete :purge
        post :delegate
        delete :undelegate
      end
    end

    # CRUD org-level dei lookup gestibili (distinti dai lookup readonly sotto types/*) + impostazioni org.
    resources :platforms,    only: %i[index show create update destroy] # gate platforms.manage
    resources :environments, only: %i[index show create update destroy] # gate environments.manage
    resource  :organization, only: %i[show update]                      # gate organization.manage (update)
    resources :alert_rules,  only: %i[index show create update destroy] # alerting org-level (gate alerts.manage)
    resources :alert_channels, only: %i[index create destroy]           # canali esterni webhook/telegram (gate alerts.manage)
    # Notification center personale (ownership, nessuna permission key) + preferenze di alert personali.
    resources :alert_notifications, only: %i[index destroy] do
      member     { put :read }      # PUT marca letta la singola notifica
      collection { put :read_all }  # PUT marca lette tutte le non lette
    end
    resource :alert_preferences, only: %i[show update]                   # preferenze alert personali (singleton, ownership)

    # Server monitoring (org-level): fleet read gated servers.view, mutazioni servers.manage.
    resources :servers, only: %i[index show update destroy] do
      member do
        put :pause
        put :resume
        put :revoke     # l'agent riceve 403 e si ferma; l'host resta (niente re-registrazione)
        put :unrevoke
      end
    end
    # Enrollment token della flotta (reveal-once nel create) — gate servers.manage.
    resources :server_tokens, only: %i[index create destroy]

    # Token org dell'automator (cyi_a_): reveal-once nel create, revoca soft. Gate agents.manage.
    # Il CRUD `resources :agents` è stato rimosso coi typed agent (MT-9): non c'è più un catalogo da
    # gestire. Restano i due canali host-first sotto questo namespace.
    namespace :agents do
      resources :tokens, only: %i[index create destroy]
      # Pin del bundle skill (singleton org): lettura agents.view, upsert agents.manage. Origine update: CI closeyourit-skills.
      resource :skill_bundle, only: %i[show update]
    end

    # RBAC: ruoli (bundle di permessi) + team (persone con scope) — gated permissions.manage
    resources :roles, only: %i[index show create update destroy]
    resources :teams, only: %i[index show create update destroy]
    resources :members, only: %i[index update destroy] do         # membri org: lettura (members.view), anagrafica (members.edit), rimozione (members.manage)
      resource :role,   only: :update, module: :members           # PUT cambia ruolo org (members.manage)
      resource :access, only: :update, module: :members           # PUT scope gruppi/progetti + ruoli/override (members.manage)
    end
    # Service account (membri di tipo AI, CLI-only) — gate members.manage. Parità col canale Member web:
    # CRUD + restrizione env (update) + token cyi_u_ nested (reveal-once nel create).
    namespace :service do
      resources :accounts, only: %i[index show create update destroy] do
        resources :tokens, only: %i[index create destroy], module: :accounts
      end
    end
    resources :invitations, only: %i[index create destroy] do     # onboarding cliente (gate members.invite)
      resource :resend, only: :update, module: :invitations       # PUT reinvia (rivela accept_url)
    end
    resources :log_entries, only: %i[index show] do               # stream log cross-app (scoping visibilità)
      resources :links, only: %i[create destroy], module: :log_entries # collegamenti manuali log↔errore/ticket (gate logs.link)
    end

    # CYRA-513: vulnerabilità delle dipendenze, cross-progetto come i log (project_id è un filtro,
    # non un segmento del path). Le collection stanno prima di :id, che è un UUID: nessun conflitto.
    resources :vulnerabilities, only: %i[index show] do
      collection do
        get  :runtimes                                                   # versioni di linguaggio fuori supporto
        post :rescan                                                     # scansione su richiesta (gate vulnerabilities.triage)
      end
      resource :ignore,    only: %i[update destroy], module: :vulnerabilities # PUT convivo col rischio / DELETE ci ripenso
      resource :promotion, only: :update,            module: :vulnerabilities # PUT promuovi a ticket
    end

    # CYRA-528: cockpit SEO, stessa forma delle vulnerabilità — lettura cross-progetto, triage nei
    # sub-controller singleton. I siti sono una risorsa a sé: dichiararne uno è configurazione
    # (gate seo.manage), decidere di un rilievo è triage (gate seo.triage).
    resources :seo, only: %i[index show], controller: "seo" do
      collection do
        get  :pages                                                # le pagine viste, con il loro stato
        post :rescan                                               # visita su richiesta (gate seo.manage)
      end
      resource :ignore,    only: %i[update destroy], module: :seo  # PUT ci convivo / DELETE ci ripenso
      resource :promotion, only: :update,            module: :seo  # PUT apri un ticket dal rilievo
    end
    # `show` è la scheda intera di un sito (CYRA-541): configurazione, rilievi aperti, ultimo giro e
    # velocità. Lettura → la governa la visibilità del progetto, nessuna chiave nuova.
    resources :seo_sites, only: %i[index show create update destroy]


    # Liste di todo personali (possedute): CRUD + voci + condivisione in lettura. Dati posseduti
    # dall'utente → nessuna permission key: scoping per ownership (Current.account.todo_lists),
    # find anti-BOLA 404. Le liste RICEVUTE (sola lettura) stanno in shared_todo_lists.
    resources :todo_lists, only: %i[index show create update destroy] do
      put :reorder, on: :collection                                           # PUT riordina le liste possedute (ordered_ids)
      resource  :sharing, only: %i[show update], module: :todo_lists          # GET destinatari / PUT imposta
      resources :items, only: %i[index create update destroy], module: :todo_lists do
        resource :completion, only: %i[update destroy], module: :items        # PUT fatto / DELETE annulla
      end
    end
    resources :shared_todo_lists, only: %i[index show]                        # liste ricevute (sola lettura)

    # Vault PERSONALE per-utente (`cyi personal`): CRUD + bundle (mappa decifrata) + import bulk. Dati
    # posseduti dall'utente → nessuna permission key, scoping per ownership (Current.account), anti-BOLA 404.
    resources :personal_secrets, only: %i[index create destroy] do
      get  :bundle, on: :collection   # GET mappa NAME=>value decifrata (scrive un evento read)
      post :import, on: :collection   # POST import bulk all-or-nothing
    end
    # File segreti PERSONALI (CYRA-133) da terminale: metadati (mai ciphertext) + upload + download
    # attachment. Da CYRA-641 anche storico, ripristino e cancellazione definitiva, come i file di
    # progetto; nessuna delega, che nel personale non esiste.
    resources :personal_secret_assets, only: %i[index create destroy] do
      member do
        get :download
        get :versions
        post :rollback
        delete :purge
      end
    end
    # Vault CONDIVISO org-level da terminale (`cyi shared`): metadati (mai i valori) + create (upsert su
    # un environment) + destroy (elimina l'intera variabile, tutti gli ambienti — come il web). Gate RBAC
    # org-level shared_secrets.manage (Member::SharedSecretsController).
    resources :shared_secrets, only: %i[index create destroy]

    # Richieste di modifica ai secret in attesa dell'approvazione a due (`cyi vault requests`, CYRA-230).
    # Org-level come la pagina web member/vault/change_requests: elenco delle pending sui progetti
    # visibili (anti-disclosure), approva/rifiuta col vincolo 4-eyes (gate secrets.manage sulla CR).
    namespace :vault do
      resources :change_requests, only: :index do
        member do
          post :approve   # POST applica la modifica decisa (chi approva ≠ chi ha chiesto)
          post :reject    # POST congela come rejected (reason obbligatoria)
        end
      end
    end

    # Board del carico di lavoro non-dev, team-scoped (`cyi workload`): una action appartiene a un
    # team, la vede/gestisce solo chi ne è membro (auth = appartenenza, nessuna permission key;
    # find anti-BOLA 404). participants = membri del team; promotion genera un ticket.
    namespace :workload do
      resources :actions, only: %i[index show create update destroy] do
        resources :participants, only: %i[create destroy], module: :actions   # POST aggiunge / DELETE rimuove (per account_id)
        resource  :promotion,    only: :create,            module: :actions   # POST genera un ticket dalla action
      end
    end

    # Assistente conversazionale che LEGGE i dati (CYRA-526), consumato da fuori dal sito.
    # La risposta è asincrona: POST del messaggio → 202 con l'id della risposta, poi si segue
    # quell'id finché smette di essere "in lavorazione". Non c'è streaming — sul web lo fa Turbo,
    # che a un client JSON non serve e costerebbe un WebSocket.
    # Puckies for the apps (CYRA-1022): the client polls a run while it is active, like the assistant.
    # `cyi puck connect`: the person's computer as a Puck tool (CYRA-1029).
    resources :coworker_devices, only: %i[create destroy], controller: "coworkers/devices", path: "coworkers/devices" do
      member do
        post :poll
        post "calls/:call_id", action: :answer, as: :answer
      end
    end
    resources :coworkers, only: :index do
      resources :runs, only: %i[index show create update], module: :coworkers
      resources :proposals, only: [], module: :coworkers do
        post :confirm, on: :member
        post :discard, on: :member
      end
    end

    namespace :assistant do
      resources :conversations, only: %i[index show create destroy] do
        resources :messages, only: :create, module: :conversations
      end
      # Stato di una risposta in lavorazione: è l'endpoint che il client interroga a intervalli.
      resources :messages, only: :show
    end

    # "Chiedi ai ticket" (RAG) cross-progetto: fuori da /projects/:id perché la domanda attraversa
    # tutti i ticket visibili al token, come la pagina omologa del sito.
    post "tickets/ask", to: "tickets#ask"

    # Esito delle richieste AI asincrone (il 202 di tickets/ask): finora si leggeva solo dal sito.
    namespace :ai do
      resources :requests, only: :show
    end

    # Knowledge base cross-progetto (`cyi kb`): pagine dei progetti visibili. index con ?q=
    # (semantica, fallback ILIKE) + ?kind[] + ?project (key o UUID); ask = RAG con citazioni.
    namespace :knowledge do
      # `related` = pagine collegate (wikilink) + vicine per significato, filtrate sulla
      # domanda passata in `?question=` (vedi Knowledge::RelatedPages).
      resources :pages, only: %i[index show create update destroy] do
        member { get :related }
        # I tre passaggi della revisione, distinti e in quest'ordine (CYRA-298, CYRA-642):
        # accettare/scartare la proposta e — solo dopo — segnarla come scritta fra i documenti
        # versionati. Da CYRA-642 anche la decisione si prende dal terminale (`cyi kb
        # approve/reject`), ma resta un gesto UMANO: il guard in Knowledge::Pages::ReviewGuards
        # respinge un account di servizio, che qui è l'unico canale da cui potrebbe presentarsi.
        member { post :approve }
        member { post :reject }
        member { post :consolidated }
        # File allegati alla pagina. `download` consegna il binario (mai un URL firmato nel
        # serializer, come per gli allegati dei ticket).
        resources :attachments, only: %i[index create destroy] do
          member { get :download }
        end
      end
      # Book (collezioni ordinate di pagine): list/show + add-page (POST .../books/:id/pages,
      # page_id + position 0-based) per le automazioni. Contratto CYRA-101.
      resources :books, only: %i[index show] do
        member { post :pages, action: :add_page }
      end
      post "ask", to: "pages#ask"
      # CYRA-767 — il pacchetto di contesto di UN progetto (`?project=` key o UUID): l'elenco corto
      # delle sue pagine con una riga di riassunto ciascuna, da leggere all'inizio di una sessione.
      # GET e non POST: è una lettura senza corpo, e deve poter essere richiesta anche da chi ha un
      # accesso di sola lettura.
      get "context", to: "pages#context"
    end

    # Dataset AI da terminale (CYRA-646): stesso canale del Member, che è FLAT e cross-progetto —
    # il progetto è un parametro (`project`, key o UUID), non un segmento del path. Le colonne
    # viaggiano dentro il dataset (`columns[]`): sono il suo schema, non una risorsa a sé, e sul
    # sito si dichiarano nello stesso form. Le righe sì (valori + foto multipart). Gate
    # `datasets.manage` sulle scritture; la lettura la governa la visibilità del progetto.
    resources :datasets, only: %i[index show create update destroy] do
      resources :rows, only: %i[index create update destroy], module: :datasets do
        # La foto si scarica per CODICE di colonna: una cella non ha id proprio nel contratto CLI
        # (la colonna È il parametro, come le celle della matrice prodotto). Mai un URL firmato in
        # un elenco — il binario si prende solo qui.
        get "photos/:code", on: :member, action: :photo, as: :photo
      end
      # Addestramenti e previsioni (CYRA-647): create avvia e mette in coda, show serve a seguire lo
      # stato fino al risultato (l'attesa è del chiamante, come il polling della pagina). Avviare è
      # gated `datasets.train`; leggere segue la visibilità del progetto.
      resources :trainings, only: %i[index show create], module: :datasets
      resources :predictions, only: %i[index show create], module: :datasets
    end

    resources :projects, only: %i[index show create update destroy] do
      namespace :artifacts do
        resources :source_maps, only: %i[index show create destroy]
        resources :native_symbols, only: %i[index show create destroy]
        resources :proguard_maps, only: %i[index show create destroy]
      end
      scope module: :knowledge do
        resources :publications, path: "knowledge/publications", param: :publication_key,
                                 only: :update, format: false
      end
      get "github-map", on: :collection, action: :github_map
      # controller esplicito: "guidance" è non numerabile, il default cercherebbe GuidancesController.
      resource :guidance, only: :show, module: :projects, controller: "guidance" # CYRA-74: references+procedures risolte del progetto
      # CYSK-26 — rilettura CLI dell'estratto di copertura pubblicato dalla CI (sola lettura).
      resources :coverage_reports, only: :index, module: :projects, path: "coverage"
      # CYSK-29 — telemetria d'uso: i simboli visti e chi li sta mandando (sola lettura).
      resources :usage_symbols, only: :index, module: :projects, path: "usage"
      get "usage/reporters", to: "projects/usage_reporters#index"
      resources :error_groups, only: %i[index show destroy] do                 # CYRA-192: destroy = elimina gruppo+occorrenze
        collection { post :bulk_triage }                                       # CYRA-45: triage bulk (ids[] + bulk_action)
        member do
          post  :merge                                                         # CYRA-192: fonde ids[] in questo gruppo
          post  :split                                                         # CYRA-153: estrae event_ids[] in un nuovo gruppo
          patch :assign                                                        # CYRA-153: assegna/disassegna (assignee_id)
        end
        resource :resolution, only: %i[update destroy], module: :error_groups  # PUT resolve (+cause/fix) / DELETE reopen
        resource :mute,       only: %i[update destroy], module: :error_groups  # PUT ignore  / DELETE reopen
        resource :promotion,  only: :update,            module: :error_groups  # PUT promuovi a ticket
      end
      # CYRA-153: regole di raggruppamento personalizzate del progetto (CRUD; manage gated nel controller).
      resources :error_grouping_rules, only: %i[index create update destroy]
      resources :metric_groups, only: %i[index show] do
        collection { post :bulk_triage }                                       # CYRA-45: triage bulk (ids[] + bulk_action)
        resource :promotion, only: :update, module: :metric_groups             # PUT promuovi a ticket
      end
      resource :analytics, only: :show do                                     # stats API web analytics (snapshot)
        resources :goals, only: %i[index create destroy], module: :analytics  # goal di conversione (read=visibilità)
        resource  :share, only: %i[create destroy], module: :analytics        # link pubblico condivisione dashboard
      end
      resources :ideas, only: %i[index show create update destroy] do         # idee (list/show/propose/edit/elimina)
        resource  :vote,       only: %i[update destroy], module: :ideas      # PUT vota / DELETE rimuovi voto
        resource  :archive,    only: %i[update destroy], module: :ideas      # PUT archivia / DELETE riapri
        resources :comments,   only: %i[index create destroy], module: :ideas # GET lista / POST commenta / DELETE elimina
        resources :cases,      only: %i[create update destroy], module: :ideas # POST aggiunge / PATCH modifica / DELETE elimina un case
        resources :links,      only: %i[create destroy], module: :ideas        # POST collega (related|evolution) / DELETE scollega (:id = altra idea)
        resource  :conversion, only: :update, module: :ideas                 # PUT converte in ticket (AI inline se manca la bozza)
      end
      resources :tickets, only: %i[index show create update destroy] do
        resource  :status,    only: :update,            module: :tickets       # PUT cambia stato
        resource  :assignee,  only: %i[update destroy], module: :tickets       # PUT assegna / DELETE disassegna
        resource  :reviewer,  only: %i[update destroy], module: :tickets       # PUT imposta revisore / DELETE rimuove
        resource  :milestone, only: %i[update destroy], module: :tickets       # PUT imposta / DELETE rimuove
        resources :comments,  only: %i[index create destroy], module: :tickets # GET lista / POST commenta / DELETE elimina
        # Resoconto di lavorazione (CYRA-220): singleton perché è UNO per ticket — il POST non
        # sovrascrive, scrive la versione successiva. Le versioni sono la cronologia, in sola lettura.
        resource  :report,    only: %i[show create], module: :tickets          # GET corrente / POST nuova versione
        resources :report_versions, only: %i[index show], module: :tickets, path: "report/versions"
        # Ciclo di chiarimenti (CYRA-221): stato in SOLA lettura — le domande le scrive il server
        # alla consegna del triage, non un chiamante. Sostituisce il ri-parsing del marker nei
        # commenti che oggi fanno skill di triage e automator.
        resources :clarifications, only: :index, module: :tickets              # GET stato del ciclo
        # Domande di primo livello (CYRA-783). Chiedere e rispondere sono baseline di chi vede il
        # ticket; marcare una domanda BLOCCANTE ferma la coda degli agenti e passa da tickets.edit,
        # come il ritiro. Il canale è per le PERSONE: un agente in fase read non può porre una
        # domanda da riga di comando, perché i guardrail della sandbox rifiutano ogni comando che
        # contenga `?` — e una domanda finisce per definizione con un punto interrogativo. Per gli
        # agenti l'unico canale resta il risultato di fase.
        resources :questions, only: %i[index create destroy], module: :tickets do
          resources :answers, only: :create, module: :questions
          resource  :closure, only: :update, module: :questions
        end
        # Audit della presa in carico (CYRA-76): snapshot immutabile della Guidance consegnata al claim.
        # Singleton in sola lettura (uno per ticket); "work_context" è composto → controller esplicito.
        resource  :work_context, only: :show, module: :tickets, controller: "work_context" # GET snapshot (gate tickets.audit.view)
        resource  :vote,      only: %i[update destroy], module: :tickets       # PUT vota / DELETE rimuovi voto
        resource  :watch,     only: %i[update destroy], module: :tickets       # PUT segui / DELETE smetti di seguire
        resource  :eligibility, only: :update, module: :tickets                # PUT override gate agenti (gate tickets.edit)
        # Presa in carico a termine (CYRA-294): stesso lease server-side degli host automator, con
        # titolare account. POST prende, PUT prolunga, DELETE rilascia (gate tickets.assign).
        resource  :lease,     only: %i[create update destroy], module: :tickets
        resources :links,     only: %i[index destroy], module: :tickets        # GET link ticket↔ticket / DELETE rimuovi (gate tickets.edit)
        resources :dependencies, only: %i[index create destroy], module: :tickets # GET prerequisiti / POST aggiungi / DELETE per UUID dependency (gate tickets.edit su create/destroy)
        resources :attachments, only: %i[index create destroy], module: :tickets do # GET lista / POST allega / DELETE rimuovi
          get :download, on: :member                                                # GET scarica il binario (redirect al blob)
        end
        scope module: :tickets do
          namespace :review do
            resource :rejection, only: :create  # POST respinge la review (reason obbligatoria)
            resource :approval,  only: :create  # POST approva la review (→ primo status done)
          end
        end
        # Integrazione GitHub del ticket (Fase 2): crea branch / apre PR dal ticket (gate github.manage).
        resource :github, only: [], module: :tickets, controller: "github" do
          post :branch          # POST crea branch KEY-N-slug
          post :pull_request    # POST apre PR dal branch del ticket
        end
      end
      scope module: :tokens do
        resources :provisions, path: "tokens/provisions", only: %i[create show] do
          resource :retry, only: :create, module: :provisions
        end
      end
      resources :tokens,        only: %i[index create destroy] do                # project ingest token
        resource :rotation, only: :update, module: :tokens                       # PUT rotate
      end
      # Vault: variabili d'ambiente cifrate per [progetto, environment] (cyi secrets/run).
      resources :secrets, only: %i[index create destroy], module: :projects do    # gate secrets.read/manage
        get  :value,  on: :member                                                 # GET valore di UN secret (:id = uuid o nome) — audit per-nome (gate secrets.read)
        get  :bundle, on: :collection                                             # GET mappa name=>value decifrata (gate secrets.read)
        post :import, on: :collection                                             # POST import bulk all-or-nothing (gate secrets.manage)
        post :sync,   on: :collection                                             # POST enfila il push sync verso GitHub (gate github.manage)
      end
      resources :secret_assets, only: %i[index create destroy], module: :projects do
        get :download, on: :member
        get :versions, on: :member
        post :rollback, on: :member
        delete :purge, on: :member
      end
      resource :environments, only: :update, module: :projects                   # PUT dichiara gli environment del progetto
      # PUT override capability [servers/uptime/secrets] per (progetto, ambiente). :environment_id = code o UUID.
      put "environments/:environment_id/capabilities", to: "projects/environment_capabilities#update" # gate projects.edit
      resource :platforms,    only: :update, module: :projects                   # PUT dichiara le piattaforme del progetto
      resource :settings, only: %i[show update], module: :projects               # GET/PATCH retention + flag funzionalità (gate projects.edit)
      resource :github, only: %i[show create update], module: :projects, controller: "github" # GET stato / POST aggancio / PATCH regole (gate github.manage)
      resources :servers, only: %i[create destroy], module: :projects             # POST collega / DELETE scollega host↔environment (gate uptime.manage)
      resources :monitors, only: %i[index show create update destroy] do          # uptime monitor (gate uptime.manage)
        resource :pause,        only: %i[update destroy], module: :monitors       # PUT pausa / DELETE riprendi
        resource :publication,  only: %i[update destroy], module: :monitors       # PUT pubblica status page / DELETE ritira
        resource :announcement, only: %i[show update destroy], module: :monitors  # GET/PUT/DELETE banner status page (gate uptime.manage)
        # Incidents: elimina primary + grouping/ungroup (bulk) + step della narrazione. Gate uptime.manage.
        resources :incidents, only: %i[destroy], module: :monitors do             # DELETE elimina l'incident primary
          post   "group", on: :collection, controller: "incidents/groups", action: :create  # POST unifica + primo step
          delete "group", on: :member,     controller: "incidents/groups", action: :destroy # DELETE scioglie il raggruppamento
          resources :updates, only: %i[create destroy], controller: "incidents/updates"      # POST step / DELETE step
        end
      end
      resources :milestones, only: %i[index show create update destroy]           # milestone progetto (gate projects.edit)
      # Documenti del progetto (CYRA-644): stesso archivio del tab Documents del sito, con ricerca
      # ?q= e filtro ?tag[]=. Lettura = visibilità del progetto, scrittura gated documents.manage.
      # `download` esiste solo qui: sul web il file si prende dal link diretto al blob, un client
      # JSON ha bisogno di un endpoint stabile (nessun URL firmato nel serializer).
      resources :documents, only: %i[index show create update destroy], module: :projects do
        get :download, on: :member
      end
      resources :releases, only: :index                                            # release del progetto (read-only, visibilità)
    end

    resources :cron_monitors, only: %i[index show]                       # cron/heartbeat monitor (read-only, visibilità)

    # Gruppi di monitor uptime (org-level, distinti da groups=Projects::Group). Gate uptime_groups.view/manage.
    resources :uptime_groups, only: %i[index show create update destroy] do
      resource :publication, only: %i[update destroy], module: :uptime_groups  # PUT pubblica status page / DELETE ritira
    end
  end
end
