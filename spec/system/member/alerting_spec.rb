# frozen_string_literal: true

require "rails_helper"

# NB: i Ui::SelectComponent (Stimulus) non sono pilotabili da rack_test — la logica di create/update
# delle regole è coperta dai request spec. Qui verifichiamo navigazione, notification center e presenza
# degli elementi data-test.
RSpec.describe "Member alerting", type: :system do
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

  it "owner vede la voce Alerts in sidebar, il bell in topbar e la lista regole" do
    create(:alerting_rule, organization: organization, name: "Any new error")
    sign_in_as(owner)
    visit member_alerting_rules_path

    expect_test "member-nav-alerts"
    expect_test "notification-bell"
    expect_test "member-alerting-rules"
    expect(page).to have_text("Any new error")
  end

  # CYRA-486 — le notifiche ricevute sono raggiungibili dal menu laterale, sotto le regole di avviso,
  # non più solo dalla campanella in alto.
  it "mostra le notifiche ricevute nel menu laterale, sotto le regole di avviso" do
    sign_in_as(owner)
    visit member_alerting_notifications_path

    within("#member-sidebar") do
      expect(page).to have_css("[data-test='member-nav-alerts']")
      expect(page).to have_css("[data-test='member-nav-alert-notifications'][href='#{member_alerting_notifications_path}']")
    end
  end

  it "Todos e Chat stanno in topbar accanto al bell, non in sidebar" do
    sign_in_as(owner)
    visit member_alerting_rules_path

    within("header[data-controller='ui--global-search']") do # the top bar, not the page header
      expect(page).to have_css("[data-test='member-nav-todos']")
      expect(page).to have_css("[data-test='member-nav-chat']")
      expect(page).to have_css("[data-test='notification-bell']")
    end
    within("#member-sidebar") do
      expect(page).not_to have_css("[data-test='member-nav-todos']")
      expect(page).not_to have_css("[data-test='member-nav-chat']")
    end
  end

  it "la voce Chat in topbar non mostra badge senza messaggi non letti" do
    sign_in_as(owner)
    visit member_alerting_rules_path

    expect(page).not_to have_css("[data-test='member-nav-chat-badge']")
  end

  it "la voce Chat in topbar mostra il badge coi non letti" do
    create(:alerting_notification, organization: organization, account: owner,
           event_type: :chat_message, via: :in_app, read_at: nil)
    sign_in_as(owner)
    visit member_alerting_rules_path

    expect(page).to have_css("[data-test='member-nav-chat-badge']", text: "1")
  end

  it "owner apre il form Nuova regola" do
    sign_in_as(owner)
    visit member_alerting_rules_path
    click_on_test "alerting-rule-new"

    expect_test "alerting-rule-form"
    expect_test "alerting-rule-name"
  end

  it "il notification center elenca le notifiche e permette di segnarle lette" do
    notification = create(:alerting_notification, organization: organization, account: owner,
                          via: :in_app, read_at: nil, title: "New error · Boom")
    sign_in_as(owner)
    visit member_alerting_notifications_path

    expect_test "notifications-list"
    expect(page).to have_text("New error · Boom")

    click_on_test "notification-read"
    expect(notification.reload).to be_read
  end

  it "notification center vuoto mostra l'empty state" do
    sign_in_as(owner)
    visit member_alerting_notifications_path
    expect_test "notifications-empty"
  end

  it "tab Notifiche: salva la cadenza email per-notifica" do
    sign_in_as(owner)
    visit member_notification_preferences_path

    expect_test "alerting-preferences-form"
    expect_test "pref-in-app-always"       # in-app: sempre attiva (nessun toggle)
    expect_test "settings-tab-notifications" # tab strip delle impostazioni account

    # I select cadenza sono nativi (4 opzioni) → pilotabili da rack_test. Seleziona per value (locale-agnostico).
    find("[data-test='pref-email-ticket_assigned'] option[value='weekly']").select_option
    click_on_test "alerting-preferences-submit"

    pref = Alerting::Preference.find_by(account: owner, organization: organization)
    expect(pref.email_cadences["ticket_assigned"]).to eq("weekly")
  end

  # CYRA-443 — la pagina teneva aperti tutti i gruppi insieme: 40+ avvisi da scorrere a occhio.
  it "tab Notifiche: i gruppi chiusi non mostrano i loro avvisi finché non li apri" do
    sign_in_as(owner)
    visit member_notification_preferences_path

    # Aperto solo il primo gruppo: la riga dei Ticket si vede, quella dei Server no.
    expect(page).to have_css("[data-test='pref-row-ticket_assigned']")
    expect(page).to have_no_css("[data-test='pref-row-server_cpu']")

    find("[data-test='pref-group-servers'] summary").click
    expect(page).to have_css("[data-test='pref-row-server_cpu']")
  end

  it "tab Notifiche: una configurazione pronta sistema tutte le cadenze in un gesto" do
    sign_in_as(owner)
    visit member_notification_preferences_path

    click_on_test "pref-preset-urgent_only"

    pref = Alerting::Preference.find_by(account: owner, organization: organization)
    expect(pref.email_cadences["uptime_down"]).to eq("immediate") # guasto grave: subito
    expect(pref.email_cadences["ticket_created"]).to eq("off")    # il resto tace
    expect(page).to have_text(I18n.t("member.notifications.presets.applied",
                                     name: I18n.t("member.notifications.presets.urgent_only.label")))
  end

  it "tab Telegram: mostra la guida quando l'account è scollegato" do
    sign_in_as(owner)
    visit member_telegram_connection_path

    expect_test "settings-tab-telegram"
    expect_test "pref-telegram-connection" # guida di attivazione visibile da scollegato
  end

  it "tab Telegram: account collegato → mostra Scollega invece della guida" do
    owner.update!(telegram_chat_id: "123", telegram_username: "owner", telegram_linked_at: Time.current)
    sign_in_as(owner)
    visit member_telegram_connection_path

    expect_test "pref-telegram-disconnect"
  end
end
