# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member navbar — ingresso Valhalla (god)", type: :system do
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

  # CYRA-331: l'ingresso al pannello god NON sta più tra le icone quotidiane della barra in alto
  # (dove si confondeva con Chat/notifiche), ma dentro il menu del profilo. L'etichetta testuale
  # che ne dichiara la natura è verificata nel component spec di Ui::UserMenuComponent.
  it "l'ingresso Valhalla vive nel menu del profilo, non tra le icone in alto, e porta al pannello god" do
    god = create(:account, name: "Zeus", god: true)

    sign_in_as(god)

    expect(page).to have_current_path(root_path)
    expect_test "member-user-menu"

    # Non è tra le icone quotidiane della barra in alto.
    within_test "member-bottom-nav" do
      expect(page).not_to have_css("[data-test='member-nav-valhalla']", visible: :all)
    end

    # Vive dentro il menu del profilo (il wrapper è hidden md:flex → visible: :all).
    within "[data-test='member-user-menu-wrapper']", visible: :all do
      expect(page).to have_css("[data-test='member-nav-valhalla']", visible: :all)
    end

    find("[data-test='member-nav-valhalla']", visible: :all).click
    expect(page).to have_current_path(valhalla_root_path)
  end

  it "non mostra alcun ingresso Valhalla a un account non god" do
    account = create(:account, god: false)
    org = create(:organization, name: "Demo Org")
    create(:membership, account: account, organization: org, role: :member)

    sign_in_as(account)

    expect(page).to have_current_path(root_path)
    expect_test "member-user-menu"
    expect(page).not_to have_css("[data-test='member-nav-valhalla']", visible: :all)
  end
end
