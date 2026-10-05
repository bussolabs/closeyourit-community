# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member uptime monitoring", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  let(:environment) { create(:environment, organization: org, code: "production", label: "Production").tap { |e| project.environments << e } }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def admin_account
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  it "un admin apre la lista e naviga alla status page" do
    monitor = create(:uptime_monitor, project:, environment:, url: "https://store.test/up")
    sign_in_as(admin_account)

    visit member_monitoring_monitors_path
    expect_test "member-monitors"
    expect(page).to have_text("Storefront")

    find("[data-test='monitor-link-#{monitor.id}']").click

    expect_test "member-monitor"
    expect_test "monitor-config"
    expect(page).to have_text("https://store.test/up")
  end

  it "un admin mette in pausa un monitor dal menu delle azioni" do
    monitor = create(:uptime_monitor, project:, environment:, active: true)
    sign_in_as(admin_account)
    visit member_monitoring_monitor_path(monitor)

    # La pausa vive nel menu overflow (nascosta finché non si apre): la si raggiunge comunque.
    find("[data-test='monitor-pause']", visible: :all).click

    expect_test "flash-notice"
    expect(monitor.reload.active).to be(false)
  end

  # CYRA-491 Scenario 1 — la modifica è in evidenza, le azioni rischiose in un menu separato.
  it "mette la modifica in evidenza e le azioni rischiose in un menu separato" do
    monitor = create(:uptime_monitor, project:, environment:)
    sign_in_as(admin_account)
    visit member_monitoring_monitor_path(monitor)

    # Modifica è l'unica azione principale: bottone visibile, fuori dal menu overflow.
    expect_test "monitor-edit"
    menu = find("[data-test='monitor-more-menu']")
    expect(menu).to have_no_css("[data-test='monitor-edit']", visible: :all)

    # Pausa ed eliminazione stanno nel menu secondario.
    expect(menu).to have_css("[data-test='monitor-pause']", visible: :all)
    expect(menu).to have_css("[data-test='monitor-delete']", visible: :all)
  end

  # CYRA-491 Scenario 2 — la conferma della pausa spiega la conseguenza prima di procedere.
  it "la conferma di pausa spiega che il sito non sarà più controllato" do
    monitor = create(:uptime_monitor, project:, environment:, active: true)
    sign_in_as(admin_account)
    visit member_monitoring_monitor_path(monitor)

    confirm = find("[data-test='monitor-pause']", visible: :all)["data-turbo-confirm"]
    expect(confirm).to eq(I18n.t("member.uptime.pause_confirm"))
  end

  # CYRA-491 DoD — l'eliminazione avvisa che è irreversibile prima di procedere.
  it "la conferma di eliminazione avvisa prima di procedere" do
    monitor = create(:uptime_monitor, project:, environment:)
    sign_in_as(admin_account)
    visit member_monitoring_monitor_path(monitor)

    confirm = find("[data-test='monitor-delete']", visible: :all)["data-turbo-confirm"]
    expect(confirm).to eq(I18n.t("member.uptime.delete_confirm"))
  end

  # CYRA-491 DoD — la pubblicazione è uno stato, non un comando affiancato agli altri.
  it "mostra la pubblicazione come stato e tiene il comando nel menu" do
    monitor = create(:uptime_monitor, project:, environment:)
    sign_in_as(admin_account)
    visit member_monitoring_monitor_path(monitor)

    # Stato pubblicazione visibile come chip nell'header (monitor non pubblico di default).
    within_test("monitor-publication") { expect(page).to have_text(I18n.t("member.uptime.publication_off")) }
    # Il comando pubblica non è affiancato agli altri: sta nel menu secondario.
    menu = find("[data-test='monitor-more-menu']")
    expect(menu).to have_css("[data-test='monitor-publish']", visible: :all)
  end

  it "il dettaglio progetto mostra la sezione Uptime per environment" do
    create(:uptime_monitor, project:, environment:, current_status: :up)
    sign_in_as(admin_account)

    visit member_project_path(project)

    expect_test "project-uptime"
    expect_test "project-uptime-env"
    expect(page).to have_text("Production")
  end

  it "un member assegnato vede i monitor in sola lettura (niente azioni)" do
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project:)
    monitor = create(:uptime_monitor, project:, environment:)
    sign_in_as(member)

    visit member_monitoring_monitor_path(monitor)

    expect_test "member-monitor"
    expect(page).not_to have_css("[data-test='monitor-actions']")
  end
end
