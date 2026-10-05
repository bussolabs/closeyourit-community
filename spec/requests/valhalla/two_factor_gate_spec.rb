# frozen_string_literal: true

require "rails_helper"

# Gate 2FA obbligatorio per il god in Valhalla (CYRA-170). Il god DEVE avere il 2FA attivo per operare
# nel pannello cross-tenant; senza, è mandato all'enrollment. Il 2FA-god scatta SOLO in Valhalla: un god
# senza 2FA può ancora fare login e navigare fuori da Valhalla (minimizza l'impatto sugli spec esistenti).
RSpec.describe "Valhalla · gate 2FA del god (CYRA-170)", type: :request do
  it "un god SENZA 2FA che entra in Valhalla è mandato all'enrollment" do
    god = create(:account, god: true)
    post login_path, params: { email: god.email, password: "Secret123!" } # god senza 2FA: login diretto

    get valhalla_root_path

    expect(response).to redirect_to(account_two_factor_path)
  end

  it "un god CON 2FA (secondo fattore già superato al login) entra in Valhalla" do
    god = create(:account, :with_otp, god: true)
    post login_path, params: { email: god.email, password: "Secret123!" }
    complete_two_factor(god)

    get valhalla_root_path

    expect(response).to have_http_status(:ok)
  end

  it "un god senza 2FA può comunque usare l'area account (solo Valhalla è gated)" do
    god = create(:account, god: true)
    post login_path, params: { email: god.email, password: "Secret123!" }

    get account_cli_tokens_path

    expect(response).to have_http_status(:ok)
  end

  # FIX-F: il ramo non-god del gate è raggiungibile (utente autenticato non-god che tenta Valhalla) e va
  # coperto — niente più esclusione dalla copertura che lo nascondeva.
  it "un account NON-god autenticato è rediretto a root senza entrare in Valhalla" do
    member = create(:account) # non god
    post login_path, params: { email: member.email, password: "Secret123!" }

    get valhalla_root_path

    expect(response).to redirect_to(root_path)
  end

  # FIX-5: il gate controlla la SESSIONE verificata, non solo lo stato dell'account. Una sessione creata
  # PRIMA che il 2FA fosse attivato (mai passata dal secondo fattore) non deve entrare in Valhalla anche
  # se il 2FA risulta attivo — viene terminata e rimandata al login.
  it "una sessione creata prima dell'attivazione del 2FA è terminata e rimandata al login" do
    god = create(:account, god: true) # login con la sola password: sessione non verificata
    post login_path, params: { email: god.email, password: "Secret123!" }
    enable_two_factor!(god) # 2FA attivato ALTROVE: lo stato diventa attivo, la sessione resta non verificata

    expect { get valhalla_root_path }.to change(Accounts::Session, :count).by(-1)
    expect(response).to redirect_to(login_path)
  end
end
