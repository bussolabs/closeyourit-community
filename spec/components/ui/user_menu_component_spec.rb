# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::UserMenuComponent, type: :component do
  def render_menu(**overrides)
    defaults = { name: "Ada Lovelace", logout_path: "/logout", trigger_test_id: "user-menu",
                 logout_test_id: "logout" }
    render_inline(described_class.new(**defaults.merge(overrides)))
  end

  # CYRA-898 — the bar shows only the initials; the name moves to the menu's first row.
  it "renders the trigger with initials only and the name as its accessible label" do
    render_menu(name: "Ada Lovelace")
    expect(page).to have_css("details.relative summary[data-test='user-menu'][aria-label='Ada Lovelace']")
    expect(page).to have_css("summary span.rounded-full", text: "AL")
    expect(page.find("summary").text).not_to include("Ada Lovelace")
    expect(page).to have_css("summary svg[data-icon='chevron-down']")
  end

  it "opens with the account name and email on the first row" do
    render_menu(name: "Ada Lovelace", email: "ada@example.com")
    expect(page).to have_css("[data-test='user-menu-identity']", text: "Ada Lovelace", visible: :all)
    expect(page).to have_css("[data-test='user-menu-identity']", text: "ada@example.com", visible: :all)
  end

  it "rende sempre l'azione Esci come button_to delete verso logout_path" do
    render_menu(logout_path: "/logout", logout_test_id: "logout")
    # Il pannello è dentro un <details> collassato → hidden per Capybara.
    expect(page).to have_css("form[action='/logout'] button[data-test='logout']", visible: :all)
    expect(page).to have_css("form[action='/logout'] input[name='_method'][value='delete']", visible: :all)
  end

  it "usa la label Esci di default da i18n quando non passata" do
    render_menu
    expect(page).to have_css("button[data-test='logout']", text: I18n.t("home.sign_out"), visible: :all)
  end

  context "con account_path" do
    it "rende la voce Account (link + label + test id)" do
      render_menu(account_path: "/member/preferences", account_label: "Account",
                  account_test_id: "menu-account")
      expect(page).to have_css(
        "a[href='/member/preferences'][data-test='menu-account']", text: "Account", visible: :all
      )
    end
  end

  context "senza account_path" do
    it "non rende la voce Account" do
      render_menu(account_path: nil)
      expect(page).to have_no_css("a[data-test='menu-account']", visible: :all)
      expect(page).to have_no_css("div.border-t", visible: :all)
    end
  end

  context "con valhalla_path" do
    it "rende la voce Valhalla (link corona + label + test id) separata dalle azioni quotidiane" do
      render_menu(account_path: "/member/preferences", account_label: "Account",
                  account_test_id: "menu-account", valhalla_path: "/valhalla",
                  valhalla_label: "Valhalla · God mode", valhalla_test_id: "member-nav-valhalla")
      expect(page).to have_css(
        "a[href='/valhalla'][data-test='member-nav-valhalla']", text: "Valhalla · God mode", visible: :all
      )
      expect(page).to have_css("a[data-test='member-nav-valhalla'] svg[data-icon='crown']", visible: :all)
      # Un separatore la stacca dalla voce Account (natura diversa dalle azioni quotidiane).
      expect(page).to have_css("div.border-t", visible: :all, minimum: 2)
    end

    it "rende la voce Valhalla anche senza account_path (god senza organizzazione)" do
      render_menu(account_path: nil, valhalla_path: "/valhalla",
                  valhalla_label: "Valhalla", valhalla_test_id: "member-nav-valhalla")
      expect(page).to have_css("a[data-test='member-nav-valhalla']", visible: :all)
    end
  end

  context "senza valhalla_path" do
    it "non rende la voce Valhalla" do
      render_menu(valhalla_path: nil)
      expect(page).to have_no_css("a[data-test='member-nav-valhalla']", visible: :all)
    end
  end
end
