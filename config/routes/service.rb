# Rotte di servizio: salute, identità della build, raccolta violazioni CSP, catalogo componenti in
# sviluppo, e il redirect dell'apex sul dominio canonico. Sono le PRIME dichiarate: l'apex deve
# vincere su tutto (root del sito compresa) e i controlli di salute non devono passare da nessuna
# regola più sotto.

# Catalogo componenti del design system (solo development) — vedi rules/component-catalogs.md.
mount Lookbook::Engine, at: "/lookbook" if Rails.env.development?

# Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
# Can be used by load balancers and uptime monitors to verify that the app is live.
get "up" => "rails/health#show", as: :rails_health_check

# Apex → www (301). Dal 2026-07-29 l'apex closeyour.it non passa più da Squarespace (che faceva
# questo redirect) ma punta con un CNAME Cloudflare direttamente a kamal-proxy: senza questa
# regola l'apex servirebbe il sito come secondo URL sullo stesso contenuto, e il canonical
# dichiarato al motore di ricerca (www) non corrisponderebbe più all'URL servito.
# Sta PRIMA di ogni altra rotta perché deve vincere su tutto — inclusa la dual root
# guest/autenticato più sotto. /up è escluso: i controlli di salute non seguono redirect.
# Hosts come from the environment (APEX_HOST → CANONICAL_HOST, set in config/deploy.yml), so a
# self-hosted install has no redirect unless it asks for one (CYRA-916).
if ENV["APEX_HOST"].present? && ENV["CANONICAL_HOST"].present?
  constraints(host: ENV["APEX_HOST"]) do
    match "(*path)", via: :all, to: redirect(status: 301) { |_params, request|
      "https://#{ENV["CANONICAL_HOST"]}#{request.fullpath}"
    }
  end
end

# Identità build a runtime (tag/sha/build-time) — usato dallo smoke-test CI (deploy self-verifying).
get "version" => "version#show", as: :version

# Liveness del MOTORE DEI JOB (Solid Queue), distinta da /up che resta liveness PURA dell'app. Servita
# dal web → indipendente dal worker: a worker fermo vira 503 e un guardiano ESTERNO che la interroga se
# ne accorge, così l'assenza di controlli non passa più inosservata (CYRA-209). Pubblica e senza auth.
get "up/workers" => "workers_health#show", as: :workers_health_check

# Liveness dei GIRI RICORRENTI (lo Scheduler di Solid Queue), distinta da /up/workers: i processi
# possono battere e smaltire la coda mentre nessuno accoda più i giri periodici. Serve al rilascio,
# che tiene sveglio lo staging per una finestra e qui verifica che i giri siano ripartiti davvero
# (CYRA-752). Pubblica e senza auth.
get "up/recurring" => "recurring_health#show", as: :recurring_health_check

# report-uri della Content Security Policy (report-only). Il browser POSTa qui, same-origin, ogni
# risorsa che l'enforce bloccherebbe: è il punto di raccolta che dimostra "zero violazioni" prima del
# passaggio a enforce (CYRA-229). Pubblico e senza auth, machine POST → ActionController::API.
post "csp-reports" => "csp_reports#create", as: :csp_reports
# Liveness del SERVIZIO DI EMBEDDING vista da Rails (CYEM-2): esce dalla stessa porta delle feature
# vere, quindi vede i guasti sul percorso che la smoke interna al servizio non può vedere. Distinta
# da /up, che resta liveness pura dell'app e non deve dipendere da un servizio esterno. Pubblica e
# senza auth; usata dallo smoke post-deploy.
get "up/embedding" => "embedding_health#show", as: :embedding_health_check

# Prontezza del DATABASE PRIMARY (CYRA-754): è QUESTO il path che kamal-proxy interroga al rollout,
# dichiarato in `proxy.healthcheck` di config/deploy.yml. Distinto da /up, che risponde 200 anche col
# database irraggiungibile e perciò dichiarava pronto un contenitore che non poteva servire niente.
# Pubblica e senza auth.
get "up/database" => "database_health#show", as: :database_health_check
