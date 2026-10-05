# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Members::Accesses", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:group) { create(:group, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  # Membership bersaglio: un member dell'org a cui assegnare scope.
  let!(:target) { create(:membership, organization:, role: :member) }

  it "senza bearer → 401" do
    put "/cli/v1/members/#{target.id}/access", params: { project_ids: [ project.id ] }
    expect(response).to have_http_status(:unauthorized)
  end

  it "owner imposta scope (gruppi/progetti dell'org) → 200 e progetti assegnati" do
    put "/cli/v1/members/#{target.id}/access", headers: headers,
                                               params: { confirm: "1", group_ids: [ group.id ], project_ids: [ project.id ] }

    expect(response).to have_http_status(:ok)
    expect(target.account.directly_accessible_projects).to include(project)
    expect(target.account.accessible_groups).to include(group)
  end

  it "project_id di un'altra org → ignorato (anti-BOLA, nessun errore)" do
    other_project = create(:project) # altra org

    put "/cli/v1/members/#{target.id}/access", headers: headers, params: { confirm: "1", project_ids: [ other_project.id ] }

    expect(response).to have_http_status(:ok)
    expect(target.account.directly_accessible_projects).not_to include(other_project)
  end

  it "membership di un'altra org → 404 (anti-BOLA)" do
    other = create(:membership, role: :member)

    put "/cli/v1/members/#{other.id}/access", headers: headers, params: { project_ids: [] }
    expect(response).to have_http_status(:not_found)
  end

  it "membro senza members.manage → 403" do
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

    put "/cli/v1/members/#{target.id}/access",
        headers: { "Authorization" => "Bearer #{member_secret}" }, params: { project_ids: [ project.id ] }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
  end

  it "render_error con il codice del Result quando SetMemberAccess fallisce (ramo else)" do
    allow(Connections::SetMemberAccess).to receive(:call).and_return(
      Result.err(AppError.new("accesso non valido", code: "R422-ACCESS-001",
                              status: :unprocessable_content, details: { base: [ "invalido" ] }))
    )

    put "/cli/v1/members/#{target.id}/access", headers: headers, params: { confirm: "1", project_ids: [] }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]["code"]).to eq("R422-ACCESS-001")
    expect(response.parsed_body["error"]["message"]).to eq("accesso non valido")
  end

  # Parità col canale Member: ruoli diretti + override personali via lo stesso endpoint.
  describe "ruoli diretti (role_ids) e override (overrides) — parità Member" do
    def direct_role_ids
      target.account.account_roles.where(organization_id: organization.id).pluck(:role_id)
    end

    def override_for(key)
      target.account.account_permissions.where(organization_id: organization.id, permission_key: key).pick(:effect)
    end

    it "role_ids assegna i ruoli diretti dell'org" do
      role = create(:role, organization:)

      put "/cli/v1/members/#{target.id}/access", headers: headers, params: { confirm: "1", role_ids: [ role.id ] }

      expect(response).to have_http_status(:ok)
      expect(direct_role_ids).to include(role.id)
    end

    it "overrides imposta allow/deny personali (che battono i ruoli)" do
      put "/cli/v1/members/#{target.id}/access", headers: headers,
                                                 params: { confirm: "1", overrides: { "tickets.edit" => "allow",
                                                                        "errors.triage" => "deny" } }

      expect(response).to have_http_status(:ok)
      expect(override_for("tickets.edit")).to eq("allow")
      expect(override_for("errors.triage")).to eq("deny")
    end

    it "un ruolo di un'altra org viene ignorato (anti-BOLA, nessun errore)" do
      other_role = create(:role) # altra org

      put "/cli/v1/members/#{target.id}/access", headers: headers, params: { confirm: "1", role_ids: [ other_role.id ] }

      expect(response).to have_http_status(:ok)
      expect(direct_role_ids).not_to include(other_role.id)
    end

    it "omettere role_ids NON azzera i ruoli diretti esistenti (no footgun sui client parziali)" do
      role = create(:role, organization:)
      Authorization::SetAccountRoles.call(organization:, account: target.account,
                                          role_ids: [ role.id ], actor: account)

      put "/cli/v1/members/#{target.id}/access", headers: headers, params: { confirm: "1", project_ids: [ project.id ] }

      expect(response).to have_http_status(:ok)
      expect(direct_role_ids).to include(role.id)
    end

    it "omettere overrides NON azzera gli override esistenti" do
      Authorization::SetAccountPermissions.call(organization:, account: target.account,
                                                allow_keys: [ "tickets.edit" ], actor: account)

      put "/cli/v1/members/#{target.id}/access", headers: headers, params: { confirm: "1", project_ids: [ project.id ] }

      expect(response).to have_http_status(:ok)
      expect(override_for("tickets.edit")).to eq("allow")
    end
  end

  # CYRA-156: parità CLI del guard anti-escalation. Un delegato con members.manage (NON owner) supera il
  # gate del controller ma NON può concedere permessi/ruoli che non possiede → R403-ACCESS-001.
  describe "guard anti-escalation (CYRA-156) — attore delegato non-owner" do
    let(:manager) do
      m = create(:account)
      create(:membership, account: m, organization:, role: :member)
      # members.manage concessa dall'owner (setup): il delegato passa il gate del controller.
      Authorization::SetAccountPermissions.call(organization:, account: m, allow_keys: [ "members.manage" ], actor: account)
      m
    end
    let(:manager_headers) do
      secret = Accounts::ApiTokens::Issue.call(account: manager, organization:, name: "CLI").value[:secret]
      { "Authorization" => "Bearer #{secret}" }
    end

    it "overrides con una chiave SCOPED non concedibile → R403-ACCESS-001, nessuna mutazione" do
      put "/cli/v1/members/#{target.id}/access", headers: manager_headers,
                                                 params: { confirm: "1", overrides: { "tickets.edit" => "allow" } }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-ACCESS-001")
      expect(target.account.account_permissions.where(organization_id: organization.id, permission_key: "tickets.edit")).to be_empty
    end

    it "role_ids con un ruolo che porta una chiave org-level non posseduta → R403-ACCESS-001, nessuna mutazione" do
      role = create(:role, organization:)
      create(:role_permission, role:, permission_key: "organization.manage")

      put "/cli/v1/members/#{target.id}/access", headers: manager_headers, params: { confirm: "1", role_ids: [ role.id ] }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-ACCESS-001")
      expect(target.account.account_roles.where(organization_id: organization.id)).to be_empty
    end

    # CYRA-243: progetti + ruolo non concedibile nella STESSA richiesta. Se i ruoli sono rifiutati lo
    # scope NON deve restare salvato (prima veniva committato per primo → progetti assegnati a vuoto).
    it "project_ids + role_ids non concedibili insieme → R403 e progetti NON assegnati (CYRA-243)" do
      role = create(:role, organization:)
      create(:role_permission, role:, permission_key: "organization.manage")
      visible = create(:project, organization:)
      create(:project_membership, account: manager, project: visible) # il manager lo vede: lo scope, se eseguito, passerebbe

      put "/cli/v1/members/#{target.id}/access", headers: manager_headers,
                                                 params: { confirm: "1", project_ids: [ visible.id ], role_ids: [ role.id ] }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-ACCESS-001")
      expect(target.account.account_roles.where(organization_id: organization.id)).to be_empty
      expect(target.account.directly_accessible_projects).to be_empty
    end

    it "un delegato con members.manage PUÒ ancora concedere una chiave org-level che possiede (deny non tocca il guard)" do
      # deny di una chiave scoped: restringe, sempre lecito → nessun R403.
      put "/cli/v1/members/#{target.id}/access", headers: manager_headers,
                                                 params: { confirm: "1", overrides: { "tickets.edit" => "deny" } }

      expect(response).to have_http_status(:ok)
      expect(target.account.account_permissions.find_by(organization_id: organization.id, permission_key: "tickets.edit").effect).to eq("deny")
    end
  end

  # CYRA-237: parità CLI del guard sullo SCOPE. Un delegato con members.manage (NON owner) non può
  # assegnare progetti/gruppi che non vede già → R403-ACCESS-001.
  describe "guard di visibilità sullo scope (CYRA-237) — attore delegato non-owner" do
    let(:visible_project) { create(:project, organization:) }
    let(:hidden_project) { create(:project, organization:) }
    let(:manager) do
      m = create(:account)
      create(:membership, account: m, organization:, role: :member)
      Authorization::SetAccountPermissions.call(organization:, account: m, allow_keys: [ "members.manage" ], actor: account)
      create(:project_membership, account: m, project: visible_project)
      m
    end
    let(:manager_headers) do
      secret = Accounts::ApiTokens::Issue.call(account: manager, organization:, name: "CLI").value[:secret]
      { "Authorization" => "Bearer #{secret}" }
    end

    it "assegna un progetto che NON vede → R403-ACCESS-001, nessuna assegnazione" do
      put "/cli/v1/members/#{target.id}/access", headers: manager_headers, params: { confirm: "1", project_ids: [ hidden_project.id ] }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-ACCESS-001")
      expect(target.account.directly_accessible_projects).to be_empty
    end

    it "assegna un progetto che vede → 200 e progetto assegnato" do
      put "/cli/v1/members/#{target.id}/access", headers: manager_headers, params: { confirm: "1", project_ids: [ visible_project.id ] }

      expect(response).to have_http_status(:ok)
      expect(target.account.directly_accessible_projects).to contain_exactly(visible_project)
    end

    # CYRA-243 speculare: ruolo concedibile ma progetto non visibile → è lo scope a essere rifiutato.
    # Nulla deve restare salvato, ruoli inclusi (atomicità piena).
    it "role_ids concedibili + un progetto non visibile insieme → R403 e ruoli NON assegnati (CYRA-243)" do
      role = create(:role, organization:) # ruolo senza permessi speciali: concedibile dal manager

      put "/cli/v1/members/#{target.id}/access", headers: manager_headers,
                                                 params: { confirm: "1", project_ids: [ hidden_project.id ], role_ids: [ role.id ] }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-ACCESS-001")
      expect(target.account.account_roles.where(organization_id: organization.id)).to be_empty
      expect(target.account.directly_accessible_projects).to be_empty
    end
  end
end
