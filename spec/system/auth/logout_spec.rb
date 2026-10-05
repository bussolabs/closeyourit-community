# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Logout", type: :system do
  before { driven_by(:rack_test) }

  def sign_in_as(account)
    # CYRA-170: un god deve avere il 2FA (obbligatorio per Valhalla). Lo attivo al volo e completo il
    # secondo fattore nella challenge UI; per un non-god complete_two_factor_ui è un no-op.
    enable_two_factor!(account) if account.god? && !account.otp_enabled?
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
    complete_two_factor_ui(account)
  end

  it "l'utente esce dalla home e non accede più all'area autenticata" do
    sign_in_as(create(:account, god: false))
    expect(page).to have_current_path(root_path)

    # L'Esci vive nel dropdown utente (<details> collassato → hidden per rack_test).
    find("[data-test='logout']", visible: :all).click

    expect(page).to have_current_path(login_path)
    # Da guest la root è la landing marketing (dual root), non un redirect al login…
    visit root_path
    expect_test "website-home"
    # …ma l'area autenticata resta inaccessibile.
    visit account_cli_tokens_path
    expect(page).to have_current_path(login_path)
  end

  it "il god esce da Valhalla e torna al login" do
    sign_in_as(create(:account, god: true))
    visit valhalla_root_path

    find("[data-test='valhalla-logout']", visible: :all).click

    expect(page).to have_current_path(login_path)
    visit valhalla_root_path
    expect(page).to have_current_path(login_path)
  end
end
