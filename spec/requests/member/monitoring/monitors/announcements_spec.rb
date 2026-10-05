# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::Monitors::Announcements", type: :request do
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

  describe "POST create" do
    it "owner: crea il banner del monitor" do
      sign_in(owner)
      post member_monitoring_monitor_announcement_path(monitor),
           params: { level: "maintenance", message: "Manutenzione", active: "1" }
      expect(response).to redirect_to(member_monitoring_monitor_path(monitor, tab: "public"))
      expect(monitor.reload.announcement).to have_attributes(level: "maintenance", message: "Manutenzione")
    end

    it "messaggio blank → redirect con alert, nessun banner" do
      sign_in(owner)
      post member_monitoring_monitor_announcement_path(monitor), params: { message: "  " }
      expect(response).to redirect_to(member_monitoring_monitor_path(monitor, tab: "public"))
      expect(monitor.reload.announcement).to be_nil
    end

    it "non autenticato → redirect login" do
      post member_monitoring_monitor_announcement_path(monitor), params: { message: "x" }
      expect(response).to redirect_to(login_path)
    end

    it "membro senza uptime.manage → forbidden (redirect root)" do
      sign_in(member)
      create(:project_membership, account: member, project:)
      post member_monitoring_monitor_announcement_path(monitor), params: { message: "x" }
      expect(response).to redirect_to(root_path)
      expect(monitor.reload.announcement).to be_nil
    end
  end

  describe "PATCH update" do
    it "owner: aggiorna il banner esistente" do
      sign_in(owner)
      create(:uptime_announcement, monitor:, message: "Vecchio")
      patch member_monitoring_monitor_announcement_path(monitor), params: { message: "Nuovo" }
      expect(monitor.reload.announcement.message).to eq("Nuovo")
    end
  end

  describe "DELETE destroy" do
    it "owner: rimuove il banner" do
      sign_in(owner)
      create(:uptime_announcement, monitor:)
      expect do
        delete member_monitoring_monitor_announcement_path(monitor)
      end.to change(Uptime::Announcement, :count).by(-1)
    end
  end
end
