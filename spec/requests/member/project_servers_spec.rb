# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::ProjectServers", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  # Progetto uptime-capable (ha una piattaforma web/server): il link server esiste solo su questi.
  let(:project) do
    create(:project, organization: org).tap do |p|
      p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
    end
  end
  let(:environment) { create(:environment, organization: org).tap { |e| project.environments << e } }
  let(:host) { create(:server_host, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # Member che VEDE il progetto e porta uptime.manage via ruolo (permesso scoped).
  def grant_uptime_manage(account)
    create(:project_membership, account:, project:)
    role = create(:role, organization: org, name: "Uptime ops")
    create(:role_permission, role:, permission_key: "uptime.manage")
    create(:account_role, account:, organization: org, role:)
  end

  # POST create = sincronizza la lista COMPLETA host_ids[] (multiselect della tab Environments).
  describe "POST /member/projects/:project_id/servers (sync multiselect)" do
    it "non autenticato → redirect login" do
      post member_project_servers_path(project), params: { environment_id: environment.id, host_ids: [ host.id ] }
      expect(response).to redirect_to(login_path)
    end

    it "owner collega gli host selezionati all'environment e redirige alla tab" do
      sign_in(owner)
      expect do
        post member_project_servers_path(project), params: { environment_id: environment.id, host_ids: [ host.id ] }
      end.to change(Connections::EnvironmentHost, :count).by(1)
      expect(response).to redirect_to(member_project_environments_path(project))
      expect(flash[:notice]).to be_present
      expect(Connections::EnvironmentHost.last.created_by).to eq(owner)
    end

    it "sincronizza: stacca gli host deselezionati e collega i nuovi" do
      sign_in(owner)
      host_b = create(:server_host, organization: org, name: "host-b")
      create(:environment_host, project:, environment:, host:)

      post member_project_servers_path(project), params: { environment_id: environment.id, host_ids: [ host_b.id ] }

      linked = project.server_links.where(environment:).map(&:host_id)
      expect(linked).to contain_exactly(host_b.id)
    end

    it "lista vuota stacca tutti gli host" do
      sign_in(owner)
      create(:environment_host, project:, environment:, host:)

      post member_project_servers_path(project), params: { environment_id: environment.id, host_ids: [] }

      expect(project.server_links.where(environment:)).to be_empty
    end

    it "member assegnato senza uptime.manage → redirect root (forbidden)" do
      sign_in(member)
      create(:project_membership, account: member, project:)
      expect do
        post member_project_servers_path(project), params: { environment_id: environment.id, host_ids: [ host.id ] }
      end.not_to change(Connections::EnvironmentHost, :count)
      expect(response).to redirect_to(root_path)
    end

    it "member con uptime.manage scoped collega" do
      sign_in(member)
      grant_uptime_manage(member)
      expect do
        post member_project_servers_path(project), params: { environment_id: environment.id, host_ids: [ host.id ] }
      end.to change(Connections::EnvironmentHost, :count).by(1)
    end

    it "progetto di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      foreign = create(:project)
      post member_project_servers_path(foreign), params: { environment_id: environment.id, host_ids: [ host.id ] }
      expect(response).to have_http_status(:not_found)
    end

    it "member non assegnato al progetto → 404 (non visibile)" do
      sign_in(member)
      post member_project_servers_path(project), params: { environment_id: environment.id, host_ids: [ host.id ] }
      expect(response).to have_http_status(:not_found)
    end

    it "host di un'altra org → scartato, nessun record (anti-BOLA)" do
      sign_in(owner)
      foreign_host = create(:server_host)
      expect do
        post member_project_servers_path(project), params: { environment_id: environment.id, host_ids: [ foreign_host.id ] }
      end.not_to change(Connections::EnvironmentHost, :count)
    end

    it "host revocato → scartato, nessun record" do
      sign_in(owner)
      revoked = create(:server_host, :revoked, organization: org)
      expect do
        post member_project_servers_path(project), params: { environment_id: environment.id, host_ids: [ revoked.id ] }
      end.not_to change(Connections::EnvironmentHost, :count)
    end

    it "environment non dichiarato dal progetto → alert, nessun record" do
      sign_in(owner)
      undeclared = create(:environment, organization: org)
      expect do
        post member_project_servers_path(project), params: { environment_id: undeclared.id, host_ids: [ host.id ] }
      end.not_to change(Connections::EnvironmentHost, :count)
      expect(flash[:alert]).to be_present
    end

    it "progetto non uptime-capable → alert con messaggio del gate, nessun record" do
      sign_in(owner)
      plain = create(:project, organization: org)
      plain_env = create(:environment, organization: org).tap { |e| plain.environments << e }
      expect do
        post member_project_servers_path(plain), params: { environment_id: plain_env.id, host_ids: [ host.id ] }
      end.not_to change(Connections::EnvironmentHost, :count)
      expect(flash[:alert]).to include(I18n.t("errors.messages.uptime_unsupported"))
    end

    it "doppio POST identico → idempotente, un solo record" do
      sign_in(owner)
      post member_project_servers_path(project), params: { environment_id: environment.id, host_ids: [ host.id ] }
      expect do
        post member_project_servers_path(project), params: { environment_id: environment.id, host_ids: [ host.id ] }
      end.not_to change(Connections::EnvironmentHost, :count)
      expect(flash[:notice]).to be_present
    end
  end
end
