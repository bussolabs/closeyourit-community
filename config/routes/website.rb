# Sito pubblico non autenticato: status page e badge, dashboard analytics condivisa, landing,
# root e pagine localizzate. Dopo l'area utenti perché la root è dual (guest / autenticato).

# --- Status page pubblica (canale Website::, NON autenticata) ---
# Status page pubblica di un GRUPPO di monitor, opt-in (flag public_status_enabled sul gruppo).
# Prefisso letterale `g/` per non collidere con la status per-monitor a 3 segmenti sotto (es.
# /status/g/acme/servizi-critici). Dichiarata PRIMA della per-monitor (Rails matcha in ordine):
# un'org con slug esattamente "g" verrebbe catturata qui — caso teorico (gli slug org derivano da
# nomi, mai la lettera singola "g").
get "status/g/:org_slug/:group_slug",
    to: "website/status_groups#show", as: :public_group_status,
    constraints: {
      org_slug: /[A-Za-z0-9][A-Za-z0-9\-]{0,62}/,
      group_slug: /[A-Za-z0-9][A-Za-z0-9\-]{0,62}/
    }

# Badge compatto del gruppo, incorporabile in iframe sul sito di chi usa i servizi. Stesso gate
# opt-in della pagina. Precede la gemella per-monitor per lo stesso motivo della coppia a 3
# segmenti: /status/g/acme/servizi/badge combacia ANCHE con status/:org/:key/:env/badge (org "g",
# key "acme", env "servizi") — è l'ordine di dichiarazione, non i constraints, a disambiguare.
get "status/g/:org_slug/:group_slug/badge",
    to: "website/status_groups#badge", as: :public_group_status_badge,
    constraints: {
      org_slug: /[A-Za-z0-9][A-Za-z0-9\-]{0,62}/,
      group_slug: /[A-Za-z0-9][A-Za-z0-9\-]{0,62}/
    }

# SLA/uptime di un monitor, opt-in (gated dal flag public_status_enabled). Slug leggibile:
# /status/:org_slug/:project_key/:environment_code (es. /status/acme/MYAP/production).
# project_key resta case-insensitive nel constraint (il controller normalizza upcase) per accettare
# sia /status/acme/MYAP/... sia /status/acme/myap/...; org_slug/environment_code hanno un tetto di
# lunghezza per difesa in profondità (il match resta comunque risolto solo se esiste il record).
get "status/:org_slug/:project_key/:environment_code",
    to: "website/status#show", as: :public_status,
    constraints: {
      org_slug: /[A-Za-z0-9][A-Za-z0-9\-]{0,62}/,
      project_key: /[A-Za-z0-9]{1,4}/,
      environment_code: /[A-Za-z][A-Za-z0-9_]{0,49}/
    }

# Badge compatto del monitor (gemella per-gruppo sopra): pillola pallino+stato servita con un layout
# autoconsistente, pensata per stare in un iframe dentro il sito monitorato. Stessi constraints e
# stesso gate opt-in della pagina intera.
get "status/:org_slug/:project_key/:environment_code/badge",
    to: "website/status#badge", as: :public_status_badge,
    constraints: {
      org_slug: /[A-Za-z0-9][A-Za-z0-9\-]{0,62}/,
      project_key: /[A-Za-z0-9]{1,4}/,
      environment_code: /[A-Za-z][A-Za-z0-9_]{0,49}/
    }

# --- Dashboard analytics pubblica / embed (canale Website::, NON autenticata) ---
# Condivisione read-only via slug imprevedibile (capability). GET mostra la dashboard (o il form
# password se protetta); POST verifica la password. Slug non risolto / link revocato → 404 (mai 403).
get "share/analytics/:slug", to: "website/analytics#show", as: :share_analytics
post "share/analytics/:slug", to: "website/analytics#show"

# --- Sito marketing pubblico (canale Website::, NON autenticato) ---
# Dual root: chi ha il cookie di sessione resta sulla dashboard member; il guest sulla stessa "/"
# vede la landing. Edge accettato: cookie stale → home#index → redirect login (come oggi).
constraints ->(req) { req.cookie_jar.signed[:session_id].present? } do
  root "home#index"
end
root "website/home#show", as: :website_root

# Route localizzate (rules/rails/i18n.md): EN default senza prefisso, IT sotto /it con segmenti
# tradotti da config/locales/routes/{en,it}.yml. Gli slug feature sono identici nei due locali
# (termini di prodotto); la whitelist vive nel catalogo Website::FeaturePage → slug ignoto = 404
# nel controller (nessuna costante applicativa referenziata a routes-draw time).
get "sitemap.xml", to: "website/sitemaps#show", as: :website_sitemap, defaults: { format: :xml }

scope defaults: { locale: "en" } do
  get "#{I18n.t("routes.features", locale: :en)}/:slug", to: "website/features#show", as: :website_feature
  get I18n.t("routes.integrations", locale: :en), to: "website/integrations#show", as: :website_integrations
  get "request-access", to: "website/access_requests#new", as: :request_access
  post "request-access", to: "website/access_requests#create"
  # CYRA-698 — informativa privacy. Il segmento resta "privacy" in entrambe le lingue: è la parola
  # che l'utente italiano cerca, e tradurla renderebbe il link meno riconoscibile, non più chiaro.
  get "privacy", to: "website/privacy#show", as: :privacy
end
scope "/it", defaults: { locale: "it" } do
  get "", to: "website/home#show", as: :website_root_it
  get "#{I18n.t("routes.features", locale: :it)}/:slug", to: "website/features#show", as: :website_feature_it
  get I18n.t("routes.integrations", locale: :it), to: "website/integrations#show", as: :website_integrations_it
  get "richiedi-accesso", to: "website/access_requests#new", as: :request_access_it
  post "richiedi-accesso", to: "website/access_requests#create"
  get "privacy", to: "website/privacy#show", as: :privacy_it
end

# Defines the root path route ("/")
# root "posts#index"
