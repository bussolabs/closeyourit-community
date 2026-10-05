# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Teams", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401" do
    get "/cli/v1/teams"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (org-level permissions.manage)" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "index → 200 con i team dell'org e meta" do
      team = create(:team, organization:, name: "DriverOne")

      get "/cli/v1/teams", headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |t| t["id"] }
      expect(ids).to include(team.id)
      expect(response.parsed_body["meta"]).to include("total")
    end

    it "show → 200 con il team dell'org" do
      team = create(:team, organization:, name: "DriverOne")

      get "/cli/v1/teams/#{team.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["name"]).to eq("DriverOne")
    end

    it "show di un team di un'altra org → 404 (anti-BOLA)" do
      other = create(:team)
      get "/cli/v1/teams/#{other.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "create → 201 con ruolo, scope gruppo e membri applicati" do
      role = create(:role, organization:, name: "Client")
      group = create(:group, organization:, name: "DriverOne")
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)

      expect do
        post "/cli/v1/teams", headers: headers, params: { confirm: "1",
          name: "DriverOne", color: "indigo",
          role_ids: [ role.id ], group_ids: [ group.id ], member_ids: [ member.id ]
        }
      end.to change(Teams::Team, :count).by(1)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["name"]).to eq("DriverOne")
      expect(data["role_ids"]).to eq([ role.id ])
      expect(data["group_ids"]).to eq([ group.id ])
      expect(data["member_ids"]).to eq([ member.id ])

      team = Teams::Team.find(data["id"])
      expect(team.created_by).to eq(account)
      expect(team.roles).to include(role)
      expect(team.scoped_groups).to include(group)
      expect(team.members).to include(member)
    end

    it "create minimale (solo name) → 201 senza ruoli/scope/membri" do
      post "/cli/v1/teams", headers: headers, params: { confirm: "1", name: "Vuoto" }

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["role_ids"]).to eq([])
      expect(data["group_ids"]).to eq([])
      expect(data["member_ids"]).to eq([])
    end

    it "scarta role_id e group_id di un'altra org (tenant-safe)" do
      other_role = create(:role)
      other_group = create(:group)

      post "/cli/v1/teams", headers: headers, params: { confirm: "1",
        name: "Tenant", role_ids: [ other_role.id ], group_ids: [ other_group.id ]
      }

      data = response.parsed_body["data"]
      expect(data["role_ids"]).to eq([])
      expect(data["group_ids"]).to eq([])
    end

    it "scarta un member_id che non è membro dell'org" do
      stranger = create(:account) # nessuna membership nell'org

      post "/cli/v1/teams", headers: headers, params: { confirm: "1", name: "X", member_ids: [ stranger.id ] }

      expect(response.parsed_body["data"]["member_ids"]).to eq([])
    end

    it "update → 200 e ri-sincronizza ruoli/scope" do
      team = create(:team, organization:, name: "DriverOne")
      role = create(:role, organization:)
      group = create(:group, organization:)

      put "/cli/v1/teams/#{team.id}", headers: headers, params: { confirm: "1",
        name: "DriverOne rinominato", role_ids: [ role.id ], group_ids: [ group.id ]
      }

      expect(response).to have_http_status(:ok)
      expect(team.reload.name).to eq("DriverOne rinominato")
      expect(team.roles).to include(role)
      expect(team.scoped_groups).to include(group)
    end

    # CYCL-62: cambiare un solo asse dello scope non deve svuotare l'altro (`teams update --group X`
    # cancellava tutti i progetti del team, e viceversa).
    it "update del solo gruppo → i progetti collegati restano" do
      team = create(:team, organization:, name: "DriverOne")
      project = create(:project, organization:)
      group = create(:group, organization:)
      Teams::SetTeamScope.call(team:, project_ids: [ project.id ], group_ids: [])

      put "/cli/v1/teams/#{team.id}", headers: headers, params: { confirm: "1", group_ids: [ group.id ] }

      expect(response).to have_http_status(:ok)
      expect(team.reload.scoped_projects).to contain_exactly(project)
      expect(team.scoped_groups).to contain_exactly(group)
    end

    it "update del solo progetto → i gruppi collegati restano" do
      team = create(:team, organization:, name: "DriverOne")
      project = create(:project, organization:)
      group = create(:group, organization:)
      Teams::SetTeamScope.call(team:, project_ids: [], group_ids: [ group.id ])

      put "/cli/v1/teams/#{team.id}", headers: headers, params: { confirm: "1", project_ids: [ project.id ] }

      expect(response).to have_http_status(:ok)
      expect(team.reload.scoped_groups).to contain_exactly(group)
      expect(team.scoped_projects).to contain_exactly(project)
    end

    # Passare l'asse con una lista vuota resta il modo per svuotarlo.
    it "update con project_ids vuoto → svuota i progetti (svuotamento esplicito)" do
      team = create(:team, organization:, name: "DriverOne")
      project = create(:project, organization:)
      Teams::SetTeamScope.call(team:, project_ids: [ project.id ], group_ids: [])

      put "/cli/v1/teams/#{team.id}", headers: headers, params: { confirm: "1", project_ids: [] }

      expect(response).to have_http_status(:ok)
      expect(team.reload.scoped_projects).to be_empty
    end

    it "destroy → 204" do
      team = create(:team, organization:)
      delete "/cli/v1/teams/#{team.id}", params: { confirm: "1" }, headers: headers
      expect(response).to have_http_status(:no_content)
      expect(Teams::Team).not_to exist(team.id)
    end

    it "create senza name → 422 R422-TEAM-001 con details" do
      post "/cli/v1/teams", headers: headers, params: { confirm: "1", color: "indigo" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-TEAM-001")
      expect(response.parsed_body["error"]["details"]).to have_key("name")
    end

    it "update con name vuoto → 422 R422-TEAM-001 (ramo else)" do
      team = create(:team, organization:, name: "DriverOne")

      put "/cli/v1/teams/#{team.id}", headers: headers, params: { confirm: "1", name: "" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-TEAM-001")
      expect(team.reload.name).to eq("DriverOne")
    end
  end

  context "membro senza permissions.manage" do
    before { create(:membership, account:, organization:, role: :member) }

    it "create → 403 R403-CLIAUTH-002" do
      post "/cli/v1/teams", headers: headers, params: { name: "X" }
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end

  # CYRA-237: parità CLI-team del guard sullo scope. Un delegato con permissions.manage (NON owner) non
  # può concedere al team progetti che non vede → R403-ACCESS-001, mai un falso 2xx col rifiuto ingoiato.
  context "delegato non-owner: guard di visibilità sullo scope (CYRA-237)" do
    let(:owner_account) do
      o = create(:account)
      create(:membership, account: o, organization:, role: :owner)
      o
    end
    let(:manager) { create(:account) }
    let(:visible_project) { create(:project, organization:) }
    let(:hidden_project) { create(:project, organization:) }
    let(:manager_headers) do
      create(:membership, account: manager, organization:, role: :member)
      Authorization::SetAccountPermissions.call(
        organization:, account: manager, allow_keys: [ "permissions.manage" ], actor: owner_account
      )
      create(:project_membership, account: manager, project: visible_project)
      secret = Accounts::ApiTokens::Issue.call(account: manager, organization:, name: "CLI").value[:secret]
      { "Authorization" => "Bearer #{secret}" }
    end

    it "create con un progetto che NON vede → 403 R403-ACCESS-001, team non creato" do
      expect do
        post "/cli/v1/teams", headers: manager_headers, params: { confirm: "1", name: "Ghost", project_ids: [ hidden_project.id ] }
      end.not_to change(Teams::Team, :count)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-ACCESS-001")
    end

    it "update aggiungendo un progetto che NON vede → 403, scope invariato" do
      team = create(:team, organization:, name: "Ops")
      put "/cli/v1/teams/#{team.id}", headers: manager_headers, params: { confirm: "1", project_ids: [ hidden_project.id ] }
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-ACCESS-001")
      expect(team.reload.scoped_projects).to be_empty
    end

    it "create con un progetto che vede → 201 e scope applicato" do
      post "/cli/v1/teams", headers: manager_headers, params: { confirm: "1", name: "Visible", project_ids: [ visible_project.id ] }
      expect(response).to have_http_status(:created)
      team = Teams::Team.find_by(organization:, name: "Visible")
      expect(team.scoped_projects).to contain_exactly(visible_project)
    end
  end
end
