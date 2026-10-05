# frozen_string_literal: true

require "rails_helper"

# CYRA-483 — la pagina di stato pubblica era la funzionalità di maggior valore dell'area e la si
# scopriva solo leggendo una guida che nessuna pagina richiamava: nessuna voce di menu, nessun
# indirizzo mostrato, nessuna anteprima, e il codice da incorporare arrivava solo dopo aver pubblicato.
RSpec.describe "Member::Monitoring::StatusPages (CYRA-483)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:environment) { create(:environment, organization: org).tap { |e| project.environments << e } }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "esiste la voce di menu dedicata, nel gruppo dell'infrastruttura" do
    get member_monitoring_monitors_path

    voce = Nokogiri::HTML(response.body).at_css("[data-test='member-nav-status-page']")
    expect(voce).to be_present
    expect(voce["href"]).to eq(member_monitoring_status_page_path)
  end

  it "senza niente di pubblico lo dice, invece di mostrare una pagina vuota" do
    get member_monitoring_status_page_path

    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at_css("[data-test='status-pages-empty']")).to be_present
  end

  # G1 — the empty page names the first step (where Publish is) and what shows up here after it.
  it "with nothing public says where to publish and what appears afterwards" do
    get member_monitoring_status_page_path

    empty = Capybara.string(response.body).find("[data-test='status-pages-empty']")
    expect(empty.find("[data-test='empty-example']").text).to eq(I18n.t("member.monitoring.status_pages.empty_example"))
    expect(empty.find("[data-test='status-pages-go-monitors']")[:href]).to eq(member_monitoring_monitors_path)
  end

  context "con un sito pubblicato" do
    let!(:monitor) do
      create(:uptime_monitor, project: project, environment: environment, public_status_enabled: true)
    end

    it "shows the clickable public address" do
      get member_monitoring_status_page_path

      url = Nokogiri::HTML(response.body).at_css("[data-test='status-page-url-#{monitor.id}']")
      expect(url["href"]).to include("/status/")
    end

    # CYRA-990 — preview and embed code moved to the Public page tab: each row opens it.
    it "lists one short row per public page that opens its Public page tab" do
      group = create(:uptime_group, :published, organization: org)
      get member_monitoring_status_page_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='status-page-manage-#{monitor.id}']")["href"])
        .to eq(member_monitoring_monitor_path(monitor, tab: "public"))
      expect(doc.at_css("[data-test='status-page-manage-#{group.id}']")["href"])
        .to eq(member_monitoring_uptime_group_path(group, tab: "public"))
      expect(doc.at_css("iframe")).to be_nil
    end

    it "conta cosa è esposto all'esterno" do
      get member_monitoring_status_page_path

      expect(Nokogiri::HTML(response.body).at_css("[data-test='status-pages-count-monitors']").text).to include("1")
    end
  end
end
