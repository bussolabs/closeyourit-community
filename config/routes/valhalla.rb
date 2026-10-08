# Pannello god (Valhalla) e impersonation. L'impersonation resta top-level perché l'uscita deve
# funzionare mentre Current.account è il membro impersonato.

# --- Pannello god (Valhalla, Fase B) ---
namespace :valhalla do
  root "dashboard#index"
  resources :accounts, except: %i[show] do
    member do
      patch :toggle_god, path: "god"
      post :reset_password, path: "password"
    end
  end
  resources :organizations do
    member { patch :suspend }
  end
  # Configurazione globale di sistema (god): retention log di default.
  resource :settings, only: %i[show update]
  # Support requests sent from the footer (CYRA-935); update marks one handled or new again.
  resources :support_requests, only: %i[index show update], path: "support"
  # AI provider: environment, CloseYourIt AI key or a custom one, with a live test (CYRA-916).
  resource :ai_settings, path: "ai", only: %i[show update] do
    post :test
  end
  # GitHub App and Telegram values, encrypted, with the environment as fallback (CYRA-914).
  resource :integrations, only: %i[show update] do
    post :generate
  end
  # Cruscotto di salute tecnica del sistema (god): backlog/falliti SolidQueue, tabelle in
  # crescita sul primary, stato dei servizi esterni collegati.
  resource :health, only: :show, controller: "health"
  # Public cyi skills package versions: withdraw, restore, read GitHub now (CYRA-912).
  resources :skill_releases, only: :index, path: "skills" do
    post :sync, on: :collection
    member do
      patch :withdraw
      patch :restore
    end
  end
  # "Update now" of a community install (CYRA-1035); answers 404 anywhere else.
  resource :instance_update, path: "update", only: %i[show create]
end

# Impersonation god → account (top-level: l'uscita deve funzionare mentre Current.account è il membro).
# `new` è la conferma col secondo fattore che precede l'avvio (CYRA-719).
resource :impersonation, only: %i[new create destroy]
