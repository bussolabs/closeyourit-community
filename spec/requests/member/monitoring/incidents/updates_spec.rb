# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::Incidents::Updates", type: :request do
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

  describe "POST create — step successivo" do
    it "owner: appende uno step e denormalizza la phase" do
      sign_in(owner)
      post member_monitoring_monitor_incident_updates_path(monitor, incident),
           params: { phase: "monitoring", body: "Monitoriamo" }
      expect(response).to redirect_to(member_monitoring_monitor_path(monitor))
      expect(incident.reload.phase).to eq("monitoring")
      expect(incident.updates.last.body).to eq("Monitoriamo")
    end

    it "non autenticato → redirect login" do
      post member_monitoring_monitor_incident_updates_path(monitor, incident), params: { phase: "monitoring" }
      expect(response).to redirect_to(login_path)
    end

    it "membro senza uptime.manage → forbidden (redirect root)" do
      sign_in(member)
      create(:project_membership, account: member, project:)
      post member_monitoring_monitor_incident_updates_path(monitor, incident), params: { phase: "monitoring" }
      expect(response).to redirect_to(root_path)
      expect(incident.reload.updates).to be_empty
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

      post member_monitoring_monitor_incident_updates_path(foreign, foreign_incident), params: { phase: "monitoring" }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE destroy — elimina uno step" do
    it "owner: rimuove lo step" do
      sign_in(owner)
      update = create(:uptime_incident_update, incident:, phase: "detected")
      expect do
        delete member_monitoring_monitor_incident_update_path(monitor, incident, update)
      end.to change(Uptime::IncidentUpdate, :count).by(-1)
      expect(response).to redirect_to(member_monitoring_monitor_path(monitor))
    end
  end
end
