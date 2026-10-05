# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member analytics", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:project) { create(:project, organization: org, name: "Storefront", key: "STOR", analytics_enabled: true) }

  before do
    Types::InstallDefaults.call(organization: org)
    project.platforms << Types::Platform.find_by!(organization: org, code: "web")
  end

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

  it "owner apre la dashboard dalla sidebar e vede chip, grafico, pagine e referrer" do
    create(:pageview, project:, path: "/pricing", visitor_hash: "a", referrer_host: "www.google.com",
                      browser: "Chrome", os: "macOS", occurred_at: 10.minutes.ago)
    create(:pageview, project:, path: "/pricing", visitor_hash: "b", utm_source: "newsletter",
                      occurred_at: 5.minutes.ago)
    sign_in_as(owner_account)

    # Site analytics live inside the SEO area (CYRA-535): the group opens on the SEO overview, and
    # its menu then lists the area's pages, analytics among them.
    click_on_test "member-nav-seo-overview"
    click_on_test "member-nav-analytics"

    expect_test "member-analytics"
    expect_test "analytics-counts"
    within_test("analytics-counts") { expect(page).to have_text("2") }
    expect_test "analytics-chart"
    # Il grafico pageview è reso col componente istogramma condiviso (Ui::HistogramComponent),
    # riconoscibile dal controller Stimulus e dall'hook barre — CYRA-22.
    expect(page).to have_css("[data-test='analytics-chart'] [data-controller='monitoring--histogram']")
    within_test("analytics-chart") { expect(page).to have_css("[data-test='analytics-buckets']") }
    within_test("analytics-pages") { expect(page).to have_text("/pricing") }
    within_test("analytics-referrers") { expect(page).to have_text("www.google.com") }
    within_test("analytics-devices") { expect(page).to have_text("Chrome") }
    within_test("analytics-utm") { expect(page).to have_text("newsletter") }
  end

  # CYRA-449: col periodo vuoto i riquadri non vengono più stampati tutti a zero — al loro posto c'è
  # il messaggio con l'ultima visita e il collegamento a un periodo che contiene qualcosa.
  it "cambia range coi link preservando progetto ed environment" do
    create(:pageview, project:, occurred_at: 20.days.ago, path: "/vecchia")
    sign_in_as(owner_account)

    visit member_monitoring_analytics_path(project_id: project.id)
    expect_test "analytics-range-empty"
    expect(page).not_to have_css("[data-test='analytics-pages']")

    click_on_test "range-30d"
    within_test("analytics-pages") { expect(page).to have_text("/vecchia") }
  end

  it "dal messaggio del periodo vuoto si arriva a un periodo che contiene dati" do
    create(:pageview, project:, occurred_at: 20.days.ago, path: "/vecchia")
    sign_in_as(owner_account)

    visit member_monitoring_analytics_path(project_id: project.id)
    click_on_test "analytics-range-empty-link"

    within_test("analytics-pages") { expect(page).to have_text("/vecchia") }
  end

  # CYRA-503 — il link pubblico si creava solo in fondo alla pagina, dopo quattordici riquadri che
  # nella configurazione predefinita sono vuoti: la funzione più vendibile dell'area era invisibile.
  it "crea il link pubblico dalla toolbar in cima, accanto al periodo" do
    create(:pageview, project:, path: "/pricing")
    sign_in_as(owner_account)

    visit member_monitoring_analytics_path(project_id: project.id)
    within_test("analytics-toolbar") { expect(page).to have_css("[data-test='range-selector']") }
    expect(page).not_to have_css("[data-test='analytics-share']")

    within_test("analytics-toolbar") { click_on_test "analytics-share-create" }
    conferma_azione_pericolosa

    within_test("analytics-share") { expect(page).to have_text(Analytics::Link.last.slug) }
    within_test("analytics-toolbar") { expect(page).to have_css("[data-test='analytics-share-open']") }
    expect(page).not_to have_css("[data-test='analytics-share-create']")
  end

  it "senza progetti web la voce di nav non compare e la pagina mostra l'empty state" do
    project.project_platforms.destroy_all
    sign_in_as(owner_account)

    # La voce sparisce del tutto quando nessun progetto raccoglie analytics: il gate è lo stesso di
    # prima, cambia solo che ora non porta con sé un'area intera. `visible: :all` perché le voci dei
    # gruppi chiusi restano nel DOM, e qui si vuole verificarne l'assenza vera.
    expect(page).to have_css("[data-test='member-nav-errors']", visible: :all)
    expect(page).not_to have_css("[data-test='member-nav-analytics']", visible: :all)

    visit member_monitoring_analytics_path
    expect_test "analytics-empty"
  end
end
