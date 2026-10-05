# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Login", type: :system do
  before { driven_by(:rack_test) }

  let!(:account) { create(:account, email: "ada@example.com", password: "Secret123!") }

  it "login valido porta alla home" do
    visit login_path
    fill_test "login-email", with: "ada@example.com"
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"

    expect(page).to have_current_path(root_path)
    # Questo account non è membro di nessuna organizzazione: la home lo dice, e quello è il segno
    # che si è atterrati lì (CYRA-658: l'header col saluto non c'è più).
    expect_test "home-no-org"
  end

  # CYRA-249: la registrazione self-service è chiusa — dalla pagina di accesso non si arriva più a
  # un modulo che crea account e organizzazione senza invito.
  it "non offre più di iscriversi" do
    visit login_path

    expect(page).to have_no_css("[data-test='login-to-signup']")
  end

  it "credenziali errate mostrano l'errore" do
    visit login_path
    fill_test "login-email", with: "ada@example.com"
    fill_test "login-password", with: "sbagliata"
    click_on_test "login-submit"

    expect_test "flash-alert"
    expect(page).to have_current_path(login_path)
  end
end
