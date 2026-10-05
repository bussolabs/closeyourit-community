# frozen_string_literal: true

require "rails_helper"

# Tab Incidents di Monitor › Uptime (Member::Monitoring::IncidentsController#index): feed cross-monitor
# paginato dei monitor visibili, con filtro stato aperti/risolti. Distinto dalle azioni incident
# nested per-monitor (grouping/timeline/destroy) sotto spec/requests/member/monitoring/incidents/.
RSpec.describe "Member::Monitoring uptime incidents (tab)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def capable_project(organization = org)
    create(:project, organization: organization).tap do |p|
      p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: organization))
    end
  end

  # Un monitor per [progetto, environment]: ogni chiamata usa un environment nuovo del progetto.
  def monitor_in(project, **attrs)
    env = create(:environment, organization: project.organization).tap { |e| project.environments << e }
    create(:uptime_monitor, project: project, environment: env, **attrs)
  end

  describe "GET /member/monitoring/incidents" do
    it "risponde 200 ed elenca incident aperti e risolti dei monitor visibili" do
      monitor = monitor_in(capable_project)
      open_incident = create(:uptime_incident, monitor: monitor, started_at: 2.hours.ago, resolved_at: nil)
      resolved_incident = create(:uptime_incident, monitor: monitor, started_at: 3.hours.ago, resolved_at: 2.hours.ago)
      sign_in(owner)
      get member_monitoring_incidents_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("uptime-incidents-table")
      expect(response.body).to include("uptime-incident-#{open_incident.id}")
      expect(response.body).to include("uptime-incident-#{resolved_incident.id}")
      expect(response.body).to include(member_monitoring_monitor_path(monitor))
    end

    it "col filtro status=open mostra solo gli incident aperti" do
      monitor = monitor_in(capable_project)
      open_incident = create(:uptime_incident, monitor: monitor, started_at: 2.hours.ago, resolved_at: nil)
      resolved_incident = create(:uptime_incident, monitor: monitor, started_at: 3.hours.ago, resolved_at: 2.hours.ago)
      sign_in(owner)
      get member_monitoring_incidents_path, params: { status: [ "open" ] }
      expect(response.body).to include("uptime-incident-#{open_incident.id}")
      expect(response.body).not_to include("uptime-incident-#{resolved_incident.id}")
    end

    it "col filtro status=resolved mostra solo gli incident risolti" do
      monitor = monitor_in(capable_project)
      open_incident = create(:uptime_incident, monitor: monitor, started_at: 2.hours.ago, resolved_at: nil)
      resolved_incident = create(:uptime_incident, monitor: monitor, started_at: 3.hours.ago, resolved_at: 2.hours.ago)
      sign_in(owner)
      get member_monitoring_incidents_path, params: { status: [ "resolved" ] }
      expect(response.body).to include("uptime-incident-#{resolved_incident.id}")
      expect(response.body).not_to include("uptime-incident-#{open_incident.id}")
    end

    it "esclude gli incident di monitor non visibili (altra organizzazione) — anti-BOLA" do
      create(:uptime_incident, monitor: monitor_in(capable_project), started_at: 1.hour.ago, resolved_at: nil)
      other_org = create(:organization)
      hidden = create(:uptime_incident, monitor: monitor_in(capable_project(other_org)),
                                        started_at: 1.hour.ago, resolved_at: nil)
      sign_in(owner)
      get member_monitoring_incidents_path
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("uptime-incident-#{hidden.id}")
    end

    it "col filtro project_id mostra solo gli incident dei monitor di quel progetto (deep-link dashboard)" do
      project_a = capable_project
      project_b = capable_project
      incident_a = create(:uptime_incident, monitor: monitor_in(project_a), started_at: 1.hour.ago, resolved_at: nil)
      incident_b = create(:uptime_incident, monitor: monitor_in(project_b), started_at: 1.hour.ago, resolved_at: nil)
      sign_in(owner)
      get member_monitoring_incidents_path, params: { project_id: [ project_a.id ] }
      expect(response.body).to include("uptime-incident-#{incident_a.id}")
      expect(response.body).not_to include("uptime-incident-#{incident_b.id}")
    end

    it "pagina gli incident oltre la densità di tabella" do
      monitor = monitor_in(capable_project)
      # started_at decrescente: l'ordine `recent` (started_at desc) manda il più VECCHIO in fondo → pagina 2.
      incidents = (1..(App::Constants::TABLE_PER_PAGE + 1)).map do |hours|
        create(:uptime_incident, monitor: monitor, started_at: hours.hours.ago, resolved_at: (hours - 1).minutes.ago)
      end
      oldest = incidents.last
      sign_in(owner)
      get member_monitoring_incidents_path
      expect(response.body).to include("uptime-incidents-pagination")
      expect(response.body).not_to include("uptime-incident-#{oldest.id}")
      get member_monitoring_incidents_path, params: { page: 2 }
      expect(response.body).to include("uptime-incident-#{oldest.id}")
    end

    it "reindirizza al login se non autenticato" do
      get member_monitoring_incidents_path
      expect(response).to have_http_status(:redirect)
    end
  end

  # CYRA-924 — the bar holds no count (C63): the incident count sits beside the section title.
  it "puts the incident count beside the section title, not in the bar" do
    sign_in(owner)
    create(:uptime_incident, monitor: monitor_in(capable_project), started_at: 2.hours.ago)

    get member_monitoring_incidents_path

    doc = Nokogiri::HTML(response.body)
    label = I18n.t("member.uptime.incidents_count_total", count: 1)
    expect(doc.at_css("[data-test='uptime-incidents-heading']").text.squish).to eq("#{I18n.t('member.uptime.incidents')} #{label}")
    expect(doc.at_css("[data-test='uptime-incidents-toolbar']").text).not_to include(label)
  end
end
