# frozen_string_literal: true

require "rails_helper"

# CYRA-535 — SEO era una voce di menu che apriva una pagina a schede, e le statistiche del sito
# un'area a sé per una pagina sola, qui accanto. Le due rispondono alla stessa domanda in due tempi
# — chi PUÒ arrivare sul sito, e chi ci è arrivato davvero — e da voci lontane chi apriva l'una non
# aveva modo di sapere che esistesse l'altra. Ora sono un'area sola con quattro destinazioni, e
# questa è la sua pagina d'ingresso.
RSpec.describe "Member — pagina di ingresso del SEO", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:) }

  before do
    create(:membership, account: owner, organization:, role: :owner)
    project.environments << environment
    project.project_platforms.create!(platform: create(:platform, organization:, supports_analytics: true))
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "apre coi rilievi ancora aperti, quelli critici e i siti sotto controllo" do
    sito = create(:seo_site, project:, environment:)
    create(:seo_issue, site: sito, severity: :critical)
    create(:seo_issue, site: sito, severity: :low, check_key: "missing_h1")
    create(:seo_issue, site: sito, severity: :high, check_key: "thin_content", status: :resolved)
    sign_in(owner)

    get member_seo_path

    expect(response).to have_http_status(:ok)
    conteggi = Nokogiri::HTML(response.body).at_css('[data-test="seo-counts"]').text
    expect(conteggi).to include(I18n.t("member.overviews.counts.seo_issues_open").downcase)
    expect(conteggi).to include(I18n.t("member.overviews.counts.seo_sites").downcase)
  end

  # D12 — with no site anywhere nothing was checked: "0 · nothing open" would read as a clean result.
  it "with no site, the all-projects row does not claim there is nothing open" do
    sign_in(owner)

    get member_seo_path

    row = Nokogiri::HTML(response.body).at_css('[data-test="seo-row-all"]')
    %w[issues critical pages].each do |key|
      expect(row.at_css(%([data-test="seo-cell-#{key}"]))["data-state"]).to eq("na")
    end
    expect(row.text).not_to include(I18n.t("member.overviews.seo.issues.zero"))
  end

  it "elenca le quattro destinazioni dell'area, statistiche del sito comprese" do
    project.update!(analytics_enabled: true)
    sign_in(owner)

    get member_seo_path

    indirizzi = Nokogiri::HTML(response.body).css("a").map { |a| a["href"] }
    expect(indirizzi).to include(member_monitoring_seo_sites_path, member_monitoring_seo_index_path,
                                 pages_member_monitoring_seo_index_path, member_monitoring_analytics_path)
  end

  # CYRA-883 — the index trail is gone; the sidebar says which area the page belongs to.
  it "site analytics belong to the SEO area" do
    project.update!(analytics_enabled: true)
    sign_in(owner)

    get member_monitoring_analytics_path

    expect(response).to have_http_status(:ok)
    group = Nokogiri::HTML(response.body).at_css('#member-sidebar [data-test="member-nav-seo-overview"]')
    expect(group["aria-current"]).to eq("true")
  end
end
