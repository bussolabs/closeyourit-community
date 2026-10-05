# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member logs", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:project) { create(:project, organization: org, name: "Storefront", key: "STOR") }

  before { Types::InstallDefaults.call(organization: org) }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def owner_account
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  it "owner apre lo stream, naviga al dettaglio e vede attributi + correlazione di richiesta" do
    entry = create(:log_entry, project:, message: "payment webhook received", trace_id: "tr-1",
                               data: { "amount_cents" => 4200 }, logger_name: "payments")
    create(:log_entry, project:, trace_id: "tr-1", message: "sibling line in same request")
    sign_in_as(owner_account)

    visit member_monitoring_log_entries_path
    expect_test "log-entries-table"
    expect(page).to have_text("payment webhook received")

    find("[data-test='log-entry-link-#{entry.id}']").click

    expect_test "member-log-entry"
    expect(page).to have_text("payment webhook received")
    expect_test "log-attributes"
    expect(page).to have_text("amount_cents")
    expect_test "log-request"
    expect(page).to have_text("sibling line in same request")
  end

  it "owner filtra lo stream con la ricerca testo della toolbar" do
    create(:log_entry, project:, message: "payment received")
    create(:log_entry, project:, message: "user signed in")
    sign_in_as(owner_account)

    visit member_monitoring_log_entries_path
    fill_test "logs-search", with: "payment"
    click_on_test "logs-filter"

    expect(page).to have_text("payment received")
    expect(page).to have_no_text("user signed in")
  end

  it "filtra per livello (toolbar) mostrando solo i log corrispondenti" do
    create(:log_entry, project:, level: :error, message: "boom failure")
    create(:log_entry, project:, level: :info, message: "calm notice")
    sign_in_as(owner_account)

    visit member_monitoring_log_entries_path(level: [ "error" ])

    expect(page).to have_text("boom failure")
    expect(page).to have_no_text("calm notice")
  end

  it "restringe lo stream a una finestra temporale (from/to) — CYRA-56" do
    create(:log_entry, project:, message: "spike during incident", occurred_at: Time.zone.local(2026, 7, 9, 14, 5))
    create(:log_entry, project:, message: "calm hours earlier", occurred_at: Time.zone.local(2026, 7, 9, 10, 0))
    sign_in_as(owner_account)

    # CYRA-340, CYRA-924: the two dates live under "Custom" of the period chip in the Filters menu.
    visit member_monitoring_log_entries_path(range: "custom")
    click_on_test "filter-range-trigger"
    fill_test "logs-range-from", with: "2026-07-09T14:00"
    fill_test "logs-range-to", with: "2026-07-09T14:10"
    click_on_test "logs-filter"

    expect(page).to have_text("spike during incident")
    expect(page).to have_no_text("calm hours earlier")
  end

  it "mostra l'empty state quando non ci sono log" do
    sign_in_as(owner_account)
    visit member_monitoring_log_entries_path
    expect_test "logs-empty"
  end

  # CYRA-61: uno stream vuoto (log purgato dalla retention) deve spiegare la finestra, altrimenti sembra
  # un bug "i log non arrivano". Il progetto esiste ma non ha (più) log.
  it "l'empty state spiega la finestra di retention dei log (CYRA-61)" do
    project
    sign_in_as(owner_account)
    visit member_monitoring_log_entries_path
    expect_test "logs-empty"
    expect_test "logs-retention-note"
    expect(page).to have_text(
      I18n.t("member.monitoring.logs.retention_note.single", count: Logs::Constants::RETENTION_DEFAULT_DAYS)
    )
  end

  it "mostra no-match quando i filtri non corrispondono a nulla" do
    create(:log_entry, project:, message: "something here")
    sign_in_as(owner_account)
    visit member_monitoring_log_entries_path(q: "zzz-nonexistent")
    expect_test "logs-no-match"
  end

  it "owner collega manualmente un errore al log" do
    entry = create(:log_entry, project:, message: "boom in checkout")
    group = create(:error_group, project:, title: "RuntimeError checkout")
    sign_in_as(owner_account)

    visit member_monitoring_log_entry_path(entry)
    # CYRA-346: due tendine distinte (errori / ticket) e il titolo intero come etichetta, invece di
    # una tendina unica con le voci troncate a quaranta caratteri.
    expect_test "log-link-form-error"

    within("[data-test='log-link-form-error']") do
      select "RuntimeError checkout", from: "linkable"
      click_on_test "log-link-submit-error"
    end

    expect_test "log-link"
    expect(page).to have_text("RuntimeError checkout")
    expect(entry.links.count).to eq(1)
  end

  it "owner vede una sezione vuota di correlazione quando il log non ha trace_id" do
    entry = create(:log_entry, project:, trace_id: nil, message: "no trace here")
    sign_in_as(owner_account)

    visit member_monitoring_log_entry_path(entry)
    expect_test "log-request"
    expect(page).to have_text(I18n.t("member.monitoring.logs.show.no_trace"))
  end
end
