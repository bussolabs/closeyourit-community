# frozen_string_literal: true

require "rails_helper"

# Hook DOM realtime (Task C): index e show espongono gli stream + i target id usati dai broadcast di
# Uptime::RecordCheck. Qui si verifica solo il render statico (la consegna live è nel service spec).
RSpec.describe "Member::Monitoring::Monitors realtime", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) do
    create(:project, organization: org).tap do |p|
      p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
    end
  end
  let(:environment) { create(:environment, organization: org).tap { |e| project.environments << e } }
  let(:monitor) { create(:uptime_monitor, project:, environment:, current_status: :up) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET index" do
    it "sottoscrive lo stream uptime e rende stats + riga col target dom_id" do
      sign_in(owner)
      monitor
      get member_monitoring_monitors_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("turbo-cable-stream-source")        # turbo_stream_from uptime
      expect(response.body).to include('id="monitors_stats"')              # target replace stats
      expect(response.body).to include(%(id="#{ActionView::RecordIdentifier.dom_id(monitor)}")) # target riga
    end

    it "le pill (#monitors_stats) usano display:contents — un solo mt-2.5 dall'header, niente flex annidato (mt-5, CYRA-70)" do
      sign_in(owner)
      monitor
      get member_monitoring_monitors_path

      stats = Nokogiri::HTML(response.body).at_css("#monitors_stats")
      expect(stats["class"]).to eq("contents")
      expect(stats["data-test"]).to eq("monitors-stats")
    end
  end

  describe "GET show" do
    it "sottoscrive lo stream del monitor e rende i container checks + incidents" do
      sign_in(owner)
      create(:uptime_check, monitor:, up: true, status_code: 200, response_time_ms: 80)
      get member_monitoring_monitor_path(monitor)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("turbo-cable-stream-source")            # turbo_stream_from monitor
      expect(response.body).to include(%(id="monitor_checks_#{monitor.id}"))   # target prepend check
      expect(response.body).to include(%(id="monitor_incidents_#{monitor.id}")) # target replace incidents
      expect(response.body).to include('data-test="monitor-check-row"')        # check renderizzato
    end

    it "senza check: empty state ma container live presente (per il prepend)" do
      sign_in(owner)
      get member_monitoring_monitor_path(monitor)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(id="monitor_checks_#{monitor.id}"))
      expect(response.body).to include('data-test="monitor-checks-empty"')
    end

    it "il container incidents è sempre presente anche senza incident (target stabile per il replace)" do
      sign_in(owner)
      get member_monitoring_monitor_path(monitor)
      expect(response.body).to include(%(id="monitor_incidents_#{monitor.id}"))
    end
  end
end
