# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::Incidents::Groups", type: :request do
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

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account) = post(login_path, params: { email: account.email, password: "Secret123!" })

  describe "POST create — unifica + primo step" do
    it "owner: raggruppa 2 incident sotto il più vecchio, posta lo step, redirect alla show" do
      sign_in(owner)
      old = create(:uptime_incident, monitor:, started_at: 2.hours.ago)
      newer = create(:uptime_incident, monitor:, started_at: 5.minutes.ago)

      post member_monitoring_monitor_incidents_group_path(monitor),
           params: { incident_ids: [ old.id, newer.id ], phase: "investigating", body: "Indaghiamo" }

      expect(response).to redirect_to(member_monitoring_monitor_path(monitor))
      expect(newer.reload.parent_id).to eq(old.id)
      expect(old.reload.phase).to eq("investigating")
      expect(old.updates.count).to eq(1)
    end

    it "un solo incident: nessun raggruppamento, solo lo step" do
      sign_in(owner)
      inc = create(:uptime_incident, monitor:)
      post member_monitoring_monitor_incidents_group_path(monitor),
           params: { incident_ids: [ inc.id ], phase: "detected" }
      expect(inc.reload.phase).to eq("detected")
      expect(inc.parent_id).to be_nil
    end

    it "phase invalida → redirect con alert, nessuno step" do
      sign_in(owner)
      inc = create(:uptime_incident, monitor:)
      post member_monitoring_monitor_incidents_group_path(monitor),
           params: { incident_ids: [ inc.id ], phase: "bogus" }
      expect(response).to redirect_to(member_monitoring_monitor_path(monitor))
      expect(inc.reload.updates).to be_empty
    end

    it "non autenticato → redirect login" do
      inc = create(:uptime_incident, monitor:)
      post member_monitoring_monitor_incidents_group_path(monitor),
           params: { incident_ids: [ inc.id ], phase: "detected" }
      expect(response).to redirect_to(login_path)
    end

    it "membro senza uptime.manage → forbidden (redirect root), nessuno step" do
      sign_in(member)
      create(:project_membership, account: member, project:)
      inc = create(:uptime_incident, monitor:)
      post member_monitoring_monitor_incidents_group_path(monitor),
           params: { incident_ids: [ inc.id ], phase: "detected" }
      expect(response).to redirect_to(root_path)
      expect(inc.reload.updates).to be_empty
    end

    it "monitor di un'altra org (BOLA) → 404" do
      sign_in(owner)
      foreign_org = create(:organization)
      foreign_project = create(:project, organization: foreign_org).tap do |p|
        p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: foreign_org))
      end
      fenv = create(:environment, organization: foreign_org).tap { |e| foreign_project.environments << e }
      foreign = create(:uptime_monitor, project: foreign_project, environment: fenv)
      inc = create(:uptime_incident, monitor: foreign)

      post member_monitoring_monitor_incidents_group_path(foreign),
           params: { incident_ids: [ inc.id ], phase: "detected" }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE destroy — scioglie il raggruppamento" do
    it "owner: stacca i figli del primary" do
      sign_in(owner)
      primary = create(:uptime_incident, :narrated, monitor:)
      child = create(:uptime_incident, monitor:, parent: primary)

      delete member_monitoring_monitor_incident_group_path(monitor, primary)

      expect(response).to redirect_to(member_monitoring_monitor_path(monitor))
      expect(child.reload.parent_id).to be_nil
    end

    it "keep_incident_id di un figlio: lo status si sposta su quella finestra" do
      sign_in(owner)
      primary = create(:uptime_incident, :narrated, monitor:)
      create(:uptime_incident_update, incident: primary, phase: :investigating)
      keeper = create(:uptime_incident, monitor:, parent: primary)

      delete member_monitoring_monitor_incident_group_path(monitor, primary),
             params: { keep_incident_id: keeper.id }

      expect(response).to redirect_to(member_monitoring_monitor_path(monitor))
      expect(keeper.reload.parent_id).to be_nil
      expect(keeper.phase).to eq("investigating")
      expect(keeper.updates.count).to eq(1)
      expect(primary.reload.phase).to be_nil
    end
  end
end
