# frozen_string_literal: true

require "rails_helper"

# CYRA-460 — la pagina di una macchina è il punto in cui si capisce che c'è un problema, e per farci
# qualcosa bisognava ricominciare da un'altra sezione: non conteneva un solo collegamento oltre a
# breadcrumb e selettori.
RSpec.describe "Member::Monitoring::Servers — e adesso? (CYRA-460)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:host) { create(:server_host, organization: org, name: "sentinel", cpu_pct: 91.5, mem_pct: 80, disk_pct: 40) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "offre di aprire un ticket sulla macchina, già intitolato e coi valori di adesso" do
    get member_monitoring_server_path(host)

    cta = Nokogiri::HTML(response.body).at_css("[data-test='server-open-ticket']")
    expect(cta).to be_present
    expect(cta["href"]).to include("title=")
    expect(CGI.unescape(cta["href"])).to include("sentinel").and include("91.5%")
  end

  it "il ticket precompilato non si porta dietro righe di journal" do
    get member_monitoring_server_path(host)

    href = CGI.unescape(Nokogiri::HTML(response.body).at_css("[data-test='server-open-ticket']")["href"])
    expect(href).not_to include("journal")
    expect(href).not_to match(/password|token|secret/i)
  end

  # CYRA-813 — «scattati QUI»: il collegamento porta il filtro della macchina, non quello dei suoi
  # progetti (che apriva la casella generale o gli avvisi di tutte le macchine dello stesso progetto).
  it "porta agli avvisi scattati su questa macchina" do
    get member_monitoring_server_path(host)

    href = Nokogiri::HTML(response.body).at_css("[data-test='server-see-alerts']")["href"]
    expect(href).to include(member_alerting_notifications_path)
    expect(href).to include("host_id=#{host.id}")
  end

  it "i progetti collegati restano cliccabili" do
    link = nil
    allow_n_plus_one do
      project = create(:project, organization: org)
      project_environment = create(:project_environment, project: project)
      link = create(:environment_host, host: host, project: project_environment.project,
                                       environment: project_environment.environment)
    end

    get member_monitoring_server_path(host)

    expect(response.body).to include(member_project_path(link.project))
  end
end
