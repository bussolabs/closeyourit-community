# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member server monitoring", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }

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

  it "un owner vede la fleet dalla sidebar e apre un server" do
    host = create(:server_host, organization: org, name: "apps", status: :up, last_seen_at: Time.current,
                  cpu_pct: 12.5, mem_pct: 40.0, disk_pct: 55.0,
                  systemd_services: [ { "name" => "ssh.service", "state" => "active", "sub" => "running" } ],
                  smart_data: { "nvme0" => { "status" => "PASSED", "model" => "Samsung" } })
    create(:server_sample, host: host, recorded_at: 1.minute.ago)
    create(:server_container_sample, host: host, name: "web", recorded_at: 1.minute.ago)
    sign_in_as(owner_account)

    visit member_infrastructure_path # Servers vive nella verticale Infrastructure (CYRA-139)
    click_on_test "member-nav-servers"
    expect_test "servers-table"
    expect(page).to have_text("apps")

    find("[data-test='server-link-#{host.id}']").click

    expect_test "server-show"
    expect_test "server-vitals" # the page opens on the quick overview
    click_on_test "server-tab-metrics"
    expect_test "server-charts"
    # CYRA-21: le 4 metriche di sistema sono rese con Ui::HistogramComponent (hook buckets_test_id
    # del componente condiviso, come error/metric show), non più con barre <span> a mano.
    expect_test "server-cpu-buckets"
    expect_test "server-mem-buckets"
    expect_test "server-disk-buckets"
    expect_test "server-temp-buckets"
    click_on_test "server-tab-workloads"
    within_test("server-containers") { expect(page).to have_text("web") }
    # CYRA-463 — nessun servizio in errore: di default il messaggio esplicito al posto dell'elenco,
    # e il servizio attivo vive nell'elenco completo (blocco richiudibile, Scenario 2).
    within_test("server-systemd") do
      expect(page).to have_text(I18n.t("member.servers.show.systemd_all_ok"))
      expect(page).to have_no_css("[data-test='server-systemd-failed']")
      within("[data-test='server-systemd-full']") { expect(page).to have_text("ssh.service") }
    end
    click_on_test "server-tab-hardware"
    within_test("server-smart") { expect(page).to have_text("nvme0") }
  end

  it "un owner vede lo stream journal e lo snapshot di una unit failed nella show" do
    host = create(:server_host, organization: org, name: "db", status: :up, last_seen_at: Time.current,
                  services_total: 40, services_failed: 1,
                  systemd_services: [ { "name" => "backup.service", "state" => "failed", "sub" => "failed" } ],
                  journal_snapshots: { "backup.service" => { "captured_at" => Time.current.iso8601,
                                                             "lines" => [ "systemd[1]: backup.service entered failed state" ] } })
    create(:server_journal_entry, host: host, organization: org, priority: 3, unit: "backup",
           message: "Backup job failed: connection refused", occurred_at: 5.minutes.ago)
    sign_in_as(owner_account)
    visit member_monitoring_server_path(host)

    click_on_test "server-tab-log"
    expect_test "server-journal-row"
    within_test("server-journal") { expect(page).to have_text("Backup job failed: connection refused") }
    click_on_test "server-tab-workloads"
    within_test("server-systemd-snapshots") { expect(page).to have_text("entered failed state") }
  end

  it "un member senza permesso non vede la voce Servers in sidebar" do
    account = create(:account)
    create(:membership, account: account, organization: org, role: :member)
    sign_in_as(account)

    expect(page).not_to have_css("[data-test='member-nav-servers']")
  end

  it "un owner rinomina un server dal form" do
    host = create(:server_host, organization: org, name: "vecchio-nome")
    sign_in_as(owner_account)
    visit edit_member_monitoring_server_path(host)

    fill_test "server-name", with: "nuovo-nome"
    click_on_test "server-form-submit"
    conferma_azione_pericolosa

    expect_test "server-show"
    expect(host.reload.name).to eq("nuovo-nome")
  end

  it "un owner mette in pausa un server dalla show" do
    host = create(:server_host, organization: org, status: :up)
    sign_in_as(owner_account)
    visit member_monitoring_server_path(host)

    click_on_test "server-pause"
    conferma_azione_pericolosa

    expect(host.reload.status_paused?).to be(true)
  end

  it "un owner crea un enrollment token e vede il segreto una volta sola" do
    sign_in_as(owner_account)
    visit member_monitoring_server_tokens_path

    fill_test "server-token-name", with: "fleet"
    click_on_test "server-token-submit"
    conferma_azione_pericolosa

    expect_test "server-token-reveal"
    secret = find("[data-test='server-token-secret']").text
    expect(secret).to start_with("cyi_s_")

    click_on_test "server-token-reveal-close"
    expect(page).not_to have_text(secret)
    expect_test "server-token-row"
  end
end
