# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::Incidents::Incidents", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) do
    create(:project, organization: org).tap do |p|
      p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
    end
  end
  let(:environment) { create(:environment, organization: org).tap { |e| project.environments << e } }
  let(:monitor) { create(:uptime_monitor, project:, environment:) }
  let(:incident) { create(:uptime_incident, :narrated, monitor:) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account) = post(login_path, params: { email: account.email, password: "Secret123!" })

  describe "DELETE destroy — elimina l'incident intero" do
    it "owner: elimina incident + step e redirect" do
      sign_in(owner)
      create(:uptime_incident_update, incident:, phase: "detected")

      expect do
        delete member_monitoring_monitor_incident_path(monitor, incident)
      end.to change(Uptime::Incident, :count).by(-1)
      expect(response).to redirect_to(member_monitoring_monitor_path(monitor))
    end

    it "owner: cascade sulle finestre unificate figlie" do
      sign_in(owner)
      create(:uptime_incident, monitor:, parent: incident)

      expect do
        delete member_monitoring_monitor_incident_path(monitor, incident)
      end.to change(Uptime::Incident, :count).by(-2)
    end

    it "non autenticato → redirect login" do
      delete member_monitoring_monitor_incident_path(monitor, incident)
      expect(response).to redirect_to(login_path)
    end

    it "membro senza uptime.manage → redirect root, incident intatto" do
      sign_in(member)
      create(:project_membership, account: member, project:)

      delete member_monitoring_monitor_incident_path(monitor, incident)
      expect(response).to redirect_to(root_path)
      expect(Uptime::Incident.exists?(incident.id)).to be(true)
    end

    it "incident di un'altra org (BOLA) → 404" do
      sign_in(owner)
      foreign_org = create(:organization)
      foreign_project = create(:project, organization: foreign_org).tap do |p|
        p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: foreign_org))
      end
      fenv = create(:environment, organization: foreign_org).tap { |e| foreign_project.environments << e }
      foreign = create(:uptime_monitor, project: foreign_project, environment: fenv)
      foreign_incident = create(:uptime_incident, monitor: foreign)

      delete member_monitoring_monitor_incident_path(foreign, foreign_incident)
      expect(response).to have_http_status(:not_found)
    end

    it "incident figlio (non top-level) → 404" do
      sign_in(owner)
      child = create(:uptime_incident, monitor:, parent: incident)

      delete member_monitoring_monitor_incident_path(monitor, child)
      expect(response).to have_http_status(:not_found)
    end
  end
end
