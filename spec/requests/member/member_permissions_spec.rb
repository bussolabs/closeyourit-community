# frozen_string_literal: true

require "rails_helper"

# Estensione accessi & permessi (Fase 2): ruoli diretti + override personali allow/deny + origine.
RSpec.describe "Member access & permissions", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:target) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    @target_membership = create(:membership, account: target, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # CYRA-580 — ruoli diretti ed eccezioni stanno su due schede diverse: la pagina si apre su un
  # riepilogo di sola lettura, i comandi di modifica sono altrove.
  describe "GET access" do
    it "mostra i ruoli diretti nella scheda dell'accesso" do
      sign_in(owner)
      get access_member_member_path(@target_membership, tab: "access")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("member-direct-roles")
    end

    it "mostra le eccezioni nella scheda dedicata" do
      sign_in(owner)
      get access_member_member_path(@target_membership, tab: "overrides")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("member-overrides")
    end
  end

  describe "PATCH update_access" do
    it "assegna ruoli diretti all'account" do
      role = create(:role, organization: org)
      sign_in(owner)
      patch access_member_member_path(@target_membership),
            params: { confirm: "1", group_ids: [], project_ids: [], role_ids: [ role.id ] }
      expect(target.reload.assigned_roles.where(organization_id: org.id)).to contain_exactly(role)
    end

    it "imposta override allow/deny" do
      sign_in(owner)
      patch access_member_member_path(@target_membership),
            params: { confirm: "1", group_ids: [], project_ids: [],
                      overrides: { "tickets.edit" => "deny", "errors.triage" => "allow" } }
      perms = target.reload.account_permissions.where(organization_id: org.id)
      expect(perms.find_by(permission_key: "tickets.edit").effect).to eq("deny")
      expect(perms.find_by(permission_key: "errors.triage").effect).to eq("allow")
    end

    it "inherit rimuove un override esistente" do
      create(:account_permission, account: target, organization: org, permission_key: "tickets.edit", effect: :deny)
      sign_in(owner)
      patch access_member_member_path(@target_membership),
            params: { confirm: "1", group_ids: [], project_ids: [], overrides: { "tickets.edit" => "inherit" } }
      expect(target.reload.account_permissions.where(organization_id: org.id)).to be_empty
    end
  end
end
