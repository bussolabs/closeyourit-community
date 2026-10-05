# frozen_string_literal: true

require "rails_helper"

# Schema what-if (owner/god): endpoint di preview per member e team. Gating owner/god, anti-BOLA,
# diff pendente reso nel partial, zero persistenza.
RSpec.describe "Member access schema preview", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def role_with(name, *keys)
    role = create(:role, organization: org, name: name)
    keys.each { |k| create(:role_permission, role: role, permission_key: k) }
    role
  end

  # Rende un membro capace di PASSARE il gate di pagina (members.manage / permissions.manage)
  # pur NON essendo owner → deve comunque essere respinto dal gate owner/god.
  def grant(account, *keys)
    create(:account_role, account: account, organization: org, role: role_with("Manager", *keys))
  end

  describe "render iniziale nelle pagine (owner/god)" do
    # CYRA-580 — la pagina si apre sulla scheda di sola lettura: lì lo schema è lo stato SALVATO e
    # non c'è modulo da ascoltare, quindi nemmeno il what-if. Il collegamento a rbac-preview vive
    # nelle due schede di modifica, accanto ai comandi.
    it "GET access (member): owner vede lo schema, senza what-if sulla scheda di sola lettura" do
      sign_in(owner)
      get access_member_member_path(org.memberships.find_by!(account_id: member.id))
      expect(response.body).to include('data-test="access-schema"')
      expect(response.body).not_to include('data-controller="rbac-preview"')
    end

    it "GET access (member) ?tab=access: lo schema è wired su rbac-preview accanto al modulo" do
      sign_in(owner)
      get access_member_member_path(org.memberships.find_by!(account_id: member.id), tab: "access")
      expect(response.body).to include('data-test="access-schema"')
      expect(response.body).to include('data-controller="rbac-preview"')
    end

    it "GET access (member) ?tab=overrides: lo schema resta wired accanto ai selettori" do
      sign_in(owner)
      get access_member_member_path(org.memberships.find_by!(account_id: member.id), tab: "overrides")
      expect(response.body).to include('data-test="access-schema"')
      expect(response.body).to include('data-controller="rbac-preview"')
    end

    it "GET edit team: owner vede lo schema per-membro" do
      team = create(:team, organization: org)
      create(:team_membership, account: member, team: team)
      sign_in(owner)
      get edit_member_team_path(team)
      expect(response.body).to include('data-test="access-schema"')
    end

    it "GET access (member): un non-owner con members.manage NON vede lo schema" do
      manager = create(:account)
      create(:membership, account: manager, organization: org, role: :member)
      grant(manager, "members.manage")
      sign_in(manager)
      get access_member_member_path(org.memberships.find_by!(account_id: member.id))
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('data-test="access-schema"')
    end

    it "GET access (member): god su un target owner → 200 senza schema (l'owner vede già tutto)" do
      god = create(:account, god: true)
      create(:membership, account: god, organization: org, role: :member)
      sign_in(god)
      get access_member_member_path(org.memberships.find_by!(account_id: owner.id))
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('data-test="access-schema"')
    end

    it "GET edit team: un non-owner con permissions.manage NON vede lo schema" do
      team = create(:team, organization: org)
      manager = create(:account)
      create(:membership, account: manager, organization: org, role: :member)
      grant(manager, "permissions.manage")
      sign_in(manager)
      get edit_member_team_path(team)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('data-test="access-schema"')
    end
  end

  describe "POST access_preview (member)" do
    it "owner → 200 con lo schema" do
      sign_in(owner)
      post access_preview_member_member_path(org.memberships.find_by!(account_id: member.id))
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="access-schema"')
    end

    it "mostra la chip (nuovo) per un ruolo+scope pendente" do
      sign_in(owner)
      role = role_with("Maint", "tickets.edit")
      post access_preview_member_member_path(org.memberships.find_by!(account_id: member.id)),
           params: { confirm: "1", role_ids: [ role.id ], project_ids: [ project.id ], group_ids: [], overrides: {} }
      expect(response.body).to include('data-test="access-chip-added"')
      # Label permesso leggibile (helper authorization_permission_label, non translation_missing).
      expect(response.body).to include("Edit tickets")
      expect(response.body).not_to include("translation_missing")
    end

    # CYRA-580 — con le tre schede il modulo invia SOLO i campi della scheda aperta. Quello che non
    # arriva vale lo stato attuale, non "vuoto": altrimenti lo schema dipinge di rosso barrato ruoli,
    # progetti ed eccezioni che nessuno sta togliendo — un allarme su una rimozione che il
    # salvataggio non farebbe.
    it "dalla scheda delle eccezioni non simula la rimozione di ruoli e progetti" do
      role = role_with("Maint", "tickets.edit")
      create(:account_role, account: member, organization: org, role: role)
      create(:project_membership, account: member, project: project)
      sign_in(owner)

      post access_preview_member_member_path(org.memberships.find_by!(account_id: member.id)),
           params: { confirm: "1", overrides: { "tickets.edit" => "inherit" } }

      expect(response.body).to include('data-test="access-schema"')
      expect(response.body).not_to include('data-test="access-chip-removed"')
    end

    it "dalla scheda dell'accesso non simula la rimozione delle eccezioni personali" do
      create(:project_membership, account: member, project: project)
      Authorization::SetAccountPermissions.call(
        organization: org, account: member, allow_keys: [ "tickets.edit" ], actor: owner
      )
      sign_in(owner)

      post access_preview_member_member_path(org.memberships.find_by!(account_id: member.id)),
           params: { confirm: "1", group_ids: [], project_ids: [ project.id ], role_ids: [] }

      expect(response.body).to include('data-test="access-schema"')
      expect(response.body).not_to include('data-test="access-chip-removed"')
    end

    it "non-owner con members.manage → negato (redirect)" do
      manager = create(:account)
      create(:membership, account: manager, organization: org, role: :member)
      grant(manager, "members.manage")
      sign_in(manager)
      post access_preview_member_member_path(org.memberships.find_by!(account_id: member.id))
      expect(response).to redirect_to(root_path)
    end

    it "god → 200" do
      god = create(:account, god: true)
      create(:membership, account: god, organization: org, role: :member)
      sign_in(god)
      post access_preview_member_member_path(org.memberships.find_by!(account_id: member.id))
      expect(response).to have_http_status(:ok)
    end

    it "membership di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      foreign = create(:membership, account: create(:account),
                                    organization: create(:organization), role: :member)
      post access_preview_member_member_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "non persiste nulla (zero scrittura)" do
      sign_in(owner)
      role = role_with("Maint", "tickets.edit")
      expect do
        post access_preview_member_member_path(org.memberships.find_by!(account_id: member.id)),
             params: { role_ids: [ role.id ], project_ids: [ project.id ], group_ids: [], overrides: {} }
      end.to change(Authorization::AccountRole, :count).by(0)
        .and change(Connections::ProjectMembership, :count).by(0)
    end
  end

  describe "POST access_preview (team)" do
    let(:team) { create(:team, organization: org) }

    before { create(:team_membership, account: member, team: team) }

    it "owner → 200 con lo schema per-membro" do
      sign_in(owner)
      post access_preview_member_team_path(team)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="access-schema-subject"')
    end

    it "mostra la chip (nuovo) per un ruolo+scope pendente del team" do
      sign_in(owner)
      role = role_with("Maint", "tickets.edit")
      post access_preview_member_team_path(team),
           params: { confirm: "1", member_ids: [ member.id ], role_ids: [ role.id ],
                     project_ids: [ project.id ], group_ids: [] }
      expect(response.body).to include('data-test="access-chip-added"')
    end

    it "non-owner con permissions.manage → negato (redirect)" do
      manager = create(:account)
      create(:membership, account: manager, organization: org, role: :member)
      grant(manager, "permissions.manage")
      sign_in(manager)
      post access_preview_member_team_path(team)
      expect(response).to redirect_to(root_path)
    end

    it "team di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      foreign = create(:team, organization: create(:organization))
      post access_preview_member_team_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "non persiste nulla (zero scrittura)" do
      sign_in(owner)
      role = role_with("Maint", "tickets.edit")
      expect do
        post access_preview_member_team_path(team),
             params: { member_ids: [ member.id ], role_ids: [ role.id ],
                       project_ids: [ project.id ], group_ids: [] }
      end.to change(Authorization::TeamRole, :count).by(0)
        .and change(Connections::TeamProjectAccess, :count).by(0)
    end
  end
end
