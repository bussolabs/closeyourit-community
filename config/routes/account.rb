# Account personale e autenticazione: token CLI, accessi attivi, secondo fattore, login/logout,
# reset password e accettazione invito. Vale cross-organizzazione, quindi sta fuori da member.

# Configurazione dei propri token CLI (cross-org) — area account.
namespace :account do
  namespace :cli do
    resources :tokens, only: %i[index destroy]
  end
  # Accessi attivi del proprio account (CYRA-643): elenco dei browser aperti + chiusura di uno o di
  # tutti gli altri. `others` sta sulla collection (Rails dichiara le collection PRIMA di :id, quindi
  # non finisce catturata come una sessione con id "others").
  resources :sessions, only: %i[index destroy] do
    delete :others, on: :collection, action: :destroy_others
  end
  # Enrollment 2FA TOTP (CYRA-170): show stato + setup (QR) + enable (verifica primo codice) + disable.
  # Area account (login richiesto, nessun contesto org) così anche il god senza membership la raggiunge.
  resource :two_factor, path: "2fa", only: %i[show destroy], controller: "two_factor" do
    get  :setup
    post :enable
  end
end

# --- Autenticazione (Fase A) ---
get  "login"  => "auth/sessions#new",     as: :login
post "login"  => "auth/sessions#create"
delete "logout" => "auth/sessions#destroy", as: :logout

# Secondo fattore del login (2FA TOTP, CYRA-170): raggiunto dopo la password quando il 2FA è attivo.
get  "login/2fa" => "auth/two_factor_sessions#new",    as: :two_factor_challenge
post "login/2fa" => "auth/two_factor_sessions#create"

# Nessuna rotta di registrazione self-service (CYRA-249): /signup creava account + organizzazione +
# tutti i default da una POST anonima e senza throttle, su un sistema a uso interno. Si entra solo
# su invito (sotto) o dal provisioning god (Valhalla::OrganizationsController#provision). Tolta la
# rotta il 404 lo dà il router: niente flag da tenere spento e da riaccendere per sbaglio.

# Reset password (token) e accettazione invito (token)
resources :passwords, controller: "auth/passwords", param: :token, only: %i[new create edit update]
resources :invitations, controller: "auth/invitations", param: :token, only: %i[edit update]

# Old two-factor addresses (/account/two_factor, /login/two_factor) from links already sent.
get "account/*path", to: redirect(::Routing::LegacyPaths), constraints: ::Routing::LegacyPaths, format: false
get "login/*path", to: redirect(::Routing::LegacyPaths), constraints: ::Routing::LegacyPaths, format: false
