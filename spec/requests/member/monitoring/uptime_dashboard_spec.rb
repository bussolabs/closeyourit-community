# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring uptime dashboard", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def capable_project
    create(:project, organization: org).tap do |p|
      p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
    end
  end

  # Un monitor per [progetto, environment]: ogni chiamata usa un environment nuovo del progetto.
  def monitor_in(project, group: nil, **attrs)
    env = create(:environment, organization: org).tap { |e| project.environments << e }
    create(:uptime_monitor, project: project, environment: env, group: group, **attrs)
  end

  describe "GET index — vista raggruppata (default)" do
    it "raggruppa i monitor per gruppo e mostra la sezione Senza gruppo" do
      project = capable_project
      group = create(:uptime_group, organization: org, name: "Servizi")
      monitor_in(project, group: group, url: "https://a.test/up")
      monitor_in(project, url: "https://b.test/up")
      sign_in(owner)
      get member_monitoring_monitors_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("monitors-grouped")
      expect(response.body).to include("uptime-group-section-#{group.id}")
      expect(response.body).to include("uptime-group-section-ungrouped")
    end

    it "vista table (?view=table) mostra la tabella flat" do
      project = capable_project
      monitor_in(project, url: "https://a.test/up")
      sign_in(owner)
      get member_monitoring_monitors_path, params: { view: "table" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("monitors-table")
    end
  end

  describe "GET index — header (chip + tab)" do
    it "mostra il chip incident aperti quando c'è un incident aperto" do
      project = capable_project
      monitor = monitor_in(project, url: "https://a.test/up", current_status: :down)
      create(:uptime_incident, monitor: monitor, started_at: 1.hour.ago, resolved_at: nil)
      sign_in(owner)
      get member_monitoring_monitors_path
      expect(response.body).to include("stat-incidents-open")
    end

    it "espone le tab Monitors (attiva) e Incidents con link alla tab incident" do
      capable_project
      sign_in(owner)
      get member_monitoring_monitors_path
      expect(response.body).to include("uptime-tab-monitors")
      expect(response.body).to include("uptime-tab-incidents")
      expect(response.body).to include(member_monitoring_incidents_path)
    end

    it "regge più gruppi/monitor/incident senza N+1 (prosopite) → 200" do
      project = capable_project
      # Setup bulk (create per-record: slug del gruppo + supports_uptime del monitor per riga) —
      # non è N+1 di produzione, solo fixture di fixture. La finestra N+1 vera è il get sotto.
      allow_n_plus_one do
        3.times do |i|
          group = create(:uptime_group, organization: org, name: "G#{i}", icon: "rocket")
          monitor = monitor_in(project, group: group, url: "https://m#{i}.test/up", current_status: :down)
          create(:uptime_incident, monitor: monitor, started_at: (i + 1).hours.ago, resolved_at: nil)
        end
      end
      sign_in(owner)
      get member_monitoring_monitors_path
      expect(response).to have_http_status(:ok)
    end
  end
end
