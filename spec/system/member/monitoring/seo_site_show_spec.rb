# frozen_string_literal: true

require "rails_helper"

# CYRA-536 — nell'elenco dei siti la riga portava FUORI dall'applicazione, sul sito stesso: l'unica
# cosa che si poteva già aprire da soli. Tutto quello che il sistema sa di quel sito — i rilievi, le
# pagine, i giri fatti — si leggeva solo in elenchi globali da filtrare a mano.
RSpec.describe "Member — la scheda di un sito SEO", type: :system, js: true do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:, name: "Sito vetrina") }
  let(:environment) { create(:environment, organization:) }

  before do
    create(:membership, account: owner, organization:, role: :owner)
    Types::InstallDefaults.call(organization:)
    project.environments << environment
    project.project_platforms.create!(platform: create(:platform, organization:, supports_analytics: true))
  end

  it "dall'elenco si preme la riga e si apre la scheda del sito, non il sito" do
    sito = create(:seo_site, project:, environment:, base_url: "https://acme.example")
    pagina = create(:seo_page, site: sito, url: "https://acme.example/prezzi", path: "/prezzi")
    create(:seo_issue, site: sito, page: pagina, severity: :critical, check_key: "missing_title")
    create(:seo_audit, :completed, site: sito)
    sign_in_as(owner)

    visit member_monitoring_seo_sites_path
    find("[data-test='seo-site-row']").click

    expect(page).to have_css("[data-test='member-seo-site']", wait: 8)
    expect(page).to have_current_path(member_monitoring_seo_site_path(sito))
    within_test("seo-site-stat-open") { expect(page).to have_text("1") }
    expect(page).to have_css("[data-test='seo-site-audits']")
    expect(page).to have_text("/prezzi")
  end

  it "dalla scheda si passa ai rilievi e alle pagine di quel sito" do
    sito = create(:seo_site, project:, environment:)
    create(:seo_page, site: sito, url: "https://acme.example/blog", path: "/blog")
    sign_in_as(owner)

    visit member_monitoring_seo_site_path(sito)
    click_on_test "seo-site-tab-pages"

    expect(page).to have_css("[data-test='member-seo-site-pages']", wait: 8)
    expect(page).to have_text("/blog")
  end
end
