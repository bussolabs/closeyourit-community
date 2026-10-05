# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::ProjectEnvironmentCapabilities", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let!(:link) { create(:project_environment, project:, environment: create(:environment, organization: org)) }
  let(:environment) { link.environment }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # Member che VEDE il progetto e porta projects.edit via ruolo scoped.
  def grant_projects_edit(account)
    create(:project_membership, account:, project:)
    role = create(:role, organization: org, name: "Editor")
    create(:role_permission, role:, permission_key: "projects.edit")
    create(:account_role, account:, organization: org, role:)
  end

  def patch_capability(params)
    patch member_project_environment_capability_path(project, environment.id), params:, as: :json
  end

  describe "PATCH /member/projects/:project_id/capabilities/:id" do
    it "non autenticato → redirect login" do
      patch member_project_environment_capability_path(project, environment.id), params: { capability: "uptime", value: "off" }
      expect(response).to redirect_to(login_path)
    end

    it "owner imposta un override esplicito (forma switch: capability + value)" do
      sign_in(owner)
      patch_capability(capability: "uptime", value: "off")
      expect(response).to have_http_status(:ok)
      expect(link.reload[:uptime_enabled]).to be(false)
    end

    it "owner forza ON e poi ripristina l'eredità (inherit → nil)" do
      sign_in(owner)
      patch_capability(capability: "servers", value: "on")
      expect(link.reload[:servers_enabled]).to be(true)
      patch_capability(capability: "servers", value: "inherit")
      expect(link.reload[:servers_enabled]).to be_nil
    end

    it "accetta la forma multipla e tocca solo le capability fornite" do
      sign_in(owner)
      patch_capability(servers: "off", secrets: "on")
      link.reload
      expect(link[:servers_enabled]).to be(false)
      expect(link[:secrets_enabled]).to be(true)
      expect(link[:uptime_enabled]).to be_nil
    end

    it "owner imposta un override esplicito per la capability approval (CYRA-138)" do
      sign_in(owner)
      patch_capability(capability: "approval", value: "on")
      expect(response).to have_http_status(:ok)
      expect(link.reload[:approval_required]).to be(true)
    end

    it "owner forza approval OFF e poi ripristina l'eredità (inherit → nil)" do
      sign_in(owner)
      patch_capability(capability: "approval", value: "off")
      expect(link.reload[:approval_required]).to be(false)
      patch_capability(capability: "approval", value: "inherit")
      expect(link.reload[:approval_required]).to be_nil
    end

    it "member assegnato senza projects.edit → redirect root (forbidden)" do
      sign_in(member)
      create(:project_membership, account: member, project:)
      patch_capability(capability: "uptime", value: "off")
      expect(response).to redirect_to(root_path)
      expect(link.reload[:uptime_enabled]).to be_nil
    end

    it "member con projects.edit scoped aggiorna" do
      sign_in(member)
      grant_projects_edit(member)
      patch_capability(capability: "uptime", value: "off")
      expect(link.reload[:uptime_enabled]).to be(false)
    end

    it "progetto di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      foreign = create(:project)
      patch member_project_environment_capability_path(foreign, environment.id),
            params: { capability: "uptime", value: "off" }, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "environment non dichiarato dal progetto → 404" do
      sign_in(owner)
      undeclared = create(:environment, organization: org)
      patch member_project_environment_capability_path(project, undeclared.id),
            params: { capability: "uptime", value: "off" }, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end
end
