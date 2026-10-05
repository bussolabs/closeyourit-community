# frozen_string_literal: true

require "rails_helper"

# Tab strip delle impostazioni account (Preferenze | Notifiche | Telegram). Navigazione via data-test,
# tab attiva verificata via attributo aria-current (selettore strutturale, non testo i18n).
RSpec.describe "Member settings tabs", type: :system do
  before { driven_by(:rack_test) }

  let(:organization) { create(:organization, name: "Demo") }
  let(:owner) { create(:account) }

  before { create(:membership, account: owner, organization: organization, role: :owner) }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "su /member/preferences mostra le 3 tab con Preferenze attiva" do
    sign_in_as(owner)
    visit member_preferences_path

    expect_test "settings-tab-display"
    expect_test "settings-tab-notifications"
    expect_test "settings-tab-telegram"
    expect(page).to have_css("[data-test='settings-tab-display'][aria-current='page']")
  end

  it "click su Notifiche → /member/preferences/notifications con tab attiva" do
    sign_in_as(owner)
    visit member_preferences_path
    click_on_test "settings-tab-notifications"

    expect(page).to have_current_path(member_notification_preferences_path)
    expect(page).to have_css("[data-test='settings-tab-notifications'][aria-current='page']")
  end

  it "click su Telegram → /member/preferences/telegram con tab attiva" do
    sign_in_as(owner)
    visit member_preferences_path
    click_on_test "settings-tab-telegram"

    expect(page).to have_current_path(member_telegram_connection_path)
    expect(page).to have_css("[data-test='settings-tab-telegram'][aria-current='page']")
  end

  # FIX-D: l'enrollment 2FA (opzionale per i non-god) è raggiungibile dalle impostazioni account.
  it "click su Sicurezza → enrollment 2FA nell'area account" do
    sign_in_as(owner)
    visit member_preferences_path
    expect_test "settings-tab-security"
    click_on_test "settings-tab-security"

    expect(page).to have_current_path(account_two_factor_path)
  end
end
