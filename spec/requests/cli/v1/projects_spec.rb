# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Projects", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  # Owner → vede tutti i progetti dell'org (VisibleScope unscoped).
  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401" do
    get "/cli/v1/projects"
    expect(response).to have_http_status(:unauthorized)
  end

  it "index → 200 con i progetti visibili e meta di paginazione" do
    p1 = create(:project, organization:)
    p2 = create(:project, organization:)

    get "/cli/v1/projects", headers: headers

    expect(response).to have_http_status(:ok)
    ids = response.parsed_body["data"].map { |p| p["id"] }
    expect(ids).to include(p1.id, p2.id)
    expect(response.parsed_body["meta"]).to include("page", "per", "total", "total_pages")
  end

  it "index esclude i progetti di un'altra organizzazione" do
    mine = create(:project, organization:)
    other = create(:project) # altra org

    get "/cli/v1/projects", headers: headers

    ids = response.parsed_body["data"].map { |p| p["id"] }
    expect(ids).to include(mine.id)
    expect(ids).not_to include(other.id)
  end

  describe "GET /cli/v1/projects/github-map" do
    it "restituisce il mapping dei progetti visibili, inclusi quelli non collegati" do
      connected = create(:project, organization:, name: "Connected", key: "CONN")
      repository = create(:github_repository, project: connected,
                                              installation: create(:github_installation, organization:),
                                              full_name: "bussolabs/connected", default_branch: "develop")
      disconnected = create(:project, organization:, name: "Disconnected", key: "DISC")
      other = create(:github_repository)

      get "/cli/v1/projects/github-map", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data).to include(
        hash_including(
          "project_id" => connected.id, "project_key" => "CONN", "project_name" => "Connected",
          "repository" => { "full_name" => repository.full_name, "default_branch" => "develop" }
        ),
        hash_including(
          "project_id" => disconnected.id, "project_key" => "DISC", "project_name" => "Disconnected",
          "repository" => nil
        )
      )
      expect(data.map { |item| item["project_id"] }).not_to include(other.project_id)
      expect(response.parsed_body["meta"]).to include("page", "per", "total", "total_pages")
    end

    it "connected_only=true restituisce soltanto i progetti collegati" do
      connected = create(:project, organization:)
      create(:github_repository, project: connected,
                                 installation: create(:github_installation, organization:))
      create(:project, organization:)

      get "/cli/v1/projects/github-map", headers: headers, params: { connected_only: true }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].pluck("project_id")).to eq([ connected.id ])
      expect(response.parsed_body.dig("meta", "total")).to eq(1)
    end

    it "senza bearer restituisce 401" do
      get "/cli/v1/projects/github-map"

      expect(response).to have_http_status(:unauthorized)
    end
  end

  it "show → 200 con id e key del progetto" do
    project = create(:project, organization:)

    get "/cli/v1/projects/#{project.id}", headers: headers

    expect(response).to have_http_status(:ok)
    data = response.parsed_body["data"]
    expect(data["id"]).to eq(project.id)
    expect(data["key"]).to eq(project.key)
  end

  it "show di un progetto di un'altra org → 404 (anti-BOLA)" do
    other = create(:project)

    get "/cli/v1/projects/#{other.id}", headers: headers

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body["error"]["code"]).to eq("R404-SYSTEM-001")
  end

  describe "POST /cli/v1/projects (create, gate projects.create)" do
    it "→ 201 e crea il progetto con la key esplicita" do
      expect do
        post "/cli/v1/projects", headers: headers, params: { name: "driverone-rails", key: "DRRA" }
      end.to change(Projects::Project, :count).by(1)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["name"]).to eq("driverone-rails")
      expect(data["key"]).to eq("DRRA")
      expect(Projects::Project.find(data["id"]).created_by).to eq(account)
    end

    it "→ 201 salvando l'icona Font Awesome" do
      post "/cli/v1/projects", headers: headers, params: { name: "p", key: "PICN", icon: "rocket" }
      expect(Projects::Project.find(response.parsed_body["data"]["id"]).icon).to eq("rocket")
    end

    it "→ 201 impostando i flag di funzionalità (quick_bug_report) — parità form Member" do
      post "/cli/v1/projects", headers: headers,
           params: { name: "flagged", key: "FLAG", quick_bug_report_enabled: true }

      expect(response).to have_http_status(:created)
      created = Projects::Project.find(response.parsed_body["data"]["id"])
      expect(created.quick_bug_report_enabled).to be(true)
    end

    it "→ 201 impostando secret_approval_enabled in creazione (CYRA-138)" do
      post "/cli/v1/projects", headers: headers,
           params: { name: "protected", key: "PRT2", secret_approval_enabled: true }

      expect(response).to have_http_status(:created)
      created = Projects::Project.find(response.parsed_body["data"]["id"])
      expect(created.secret_approval_enabled).to be(true)
    end

    it "→ 201 assegnando il gruppo via group_id" do
      group = create(:group, organization:)

      post "/cli/v1/projects", headers: headers,
           params: { name: "driverone-flutter", key: "DRFL", group_id: group.id }

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["group_id"]).to eq(group.id)
    end

    it "→ 201 assegnando il gruppo via group_name" do
      group = create(:group, organization:, name: "DriverOne")

      post "/cli/v1/projects", headers: headers,
           params: { name: "driverone-angular", key: "DRAN", group_name: "DriverOne" }

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["group_id"]).to eq(group.id)
    end

    it "key omessa → 422 R422-PROJECT-001 (la key è sempre esplicita)" do
      post "/cli/v1/projects", headers: headers, params: { name: "driverone-rails" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-PROJECT-001")
    end

    it "key più lunga di 4 caratteri → 422 R422-PROJECT-001" do
      post "/cli/v1/projects", headers: headers, params: { name: "driverone-rails", key: "DRIVE" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-PROJECT-001")
    end

    it "group_id di un'altra org → 422 R422-PROJECT-002 (anti-BOLA)" do
      other_group = create(:group) # altra org

      post "/cli/v1/projects", headers: headers,
           params: { name: "x", key: "X0", group_id: other_group.id }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-PROJECT-002")
    end

    it "group_name inesistente → 422 R422-PROJECT-002" do
      post "/cli/v1/projects", headers: headers,
           params: { name: "x", key: "X1", group_name: "Inesistente" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-PROJECT-002")
    end

    it "group_id non-uuid → 422 R422-PROJECT-002 (trattato come gruppo non trovato)" do
      post "/cli/v1/projects", headers: headers,
           params: { name: "x", key: "X4", group_id: "not-a-uuid" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-PROJECT-002")
    end

    it "name blank → 422 R422-PROJECT-001 con details" do
      post "/cli/v1/projects", headers: headers, params: { key: "AB" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-PROJECT-001")
      expect(response.parsed_body["error"]["details"]).to have_key("name")
    end

    it "key fuori formato → 422 R422-PROJECT-001" do
      post "/cli/v1/projects", headers: headers, params: { name: "x", key: "ab-c" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-PROJECT-001")
    end

    it "key duplicata nell'org → 422 R422-PROJECT-001" do
      create(:project, organization:, key: "DUP")

      post "/cli/v1/projects", headers: headers, params: { name: "x", key: "DUP" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-PROJECT-001")
    end
  end

  describe "POST /cli/v1/projects — autorizzazione" do
    it "membro senza projects.create → 403 R403-CLIAUTH-002" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      post "/cli/v1/projects", headers: { "Authorization" => "Bearer #{member_secret}" },
           params: { name: "x", key: "X2" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "senza bearer → 401" do
      post "/cli/v1/projects", params: { name: "x", key: "X3" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "PUT update" do
    let(:project) { create(:project, organization:, name: "Old", key: "OLD") }

    it "owner aggiorna i campi base → 200 + dati nuovi" do
      put "/cli/v1/projects/#{project.id}", headers: headers,
                                            params: { name: "New name", color: "indigo", description: "desc" }

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["name"]).to eq("New name")
      expect(data["color"]).to eq("indigo")
      expect(project.reload.name).to eq("New name")
    end

    it "assegna un gruppo per nome (entro l'org)" do
      group = create(:group, organization:, name: "Backend")

      put "/cli/v1/projects/#{project.id}", headers: headers, params: { group_name: "Backend" }

      expect(response).to have_http_status(:ok)
      expect(project.reload.group_id).to eq(group.id)
    end

    it "aggiorna i flag di funzionalità (quick_bug_report)" do
      project.update_columns(quick_bug_report_enabled: false)

      put "/cli/v1/projects/#{project.id}", headers: headers,
                                            params: { quick_bug_report_enabled: true }

      expect(response).to have_http_status(:ok)
      expect(project.reload.quick_bug_report_enabled).to be(true)
    end

    it "aggiorna secret_approval_enabled (CYRA-138)" do
      project.update_columns(secret_approval_enabled: false)

      put "/cli/v1/projects/#{project.id}", headers: headers, params: { secret_approval_enabled: true }

      expect(response).to have_http_status(:ok)
      expect(project.reload.secret_approval_enabled).to be(true)
    end

    it "update parziale (senza group) NON tocca il gruppo già assegnato (sentinel UNSET)" do
      group = create(:group, organization:)
      project.update!(group:)

      put "/cli/v1/projects/#{project.id}", headers: headers, params: { name: "Solo nome" }

      expect(response).to have_http_status(:ok)
      expect(project.reload.name).to eq("Solo nome")
      expect(project.group_id).to eq(group.id)
    end

    it "gruppo inesistente → 422 R422-PROJECT-002" do
      put "/cli/v1/projects/#{project.id}", headers: headers, params: { group_name: "Nope" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-PROJECT-002")
    end

    it "group_id di un'altra org → 422 R422-PROJECT-002 (anti-BOLA), gruppo invariato" do
      other_group = create(:group) # altra org

      put "/cli/v1/projects/#{project.id}", headers: headers, params: { group_id: other_group.id }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-PROJECT-002")
      expect(project.reload.group_id).to be_nil
    end

    it "validazione fallita (nome vuoto) → 422 R422-PROJECT-001" do
      put "/cli/v1/projects/#{project.id}", headers: headers, params: { name: "" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-PROJECT-001")
    end

    it "progetto di un'altra organizzazione → 404 (anti-BOLA)" do
      other = create(:project)

      put "/cli/v1/projects/#{other.id}", headers: headers, params: { name: "x" }

      expect(response).to have_http_status(:not_found)
    end

    it "membro che NON vede il progetto (stessa org, nessuna assegnazione) → 404, non 403 (visibilità prima del permesso)" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      put "/cli/v1/projects/#{project.id}", headers: { "Authorization" => "Bearer #{member_secret}" },
                                            params: { name: "x" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["code"]).to eq("R404-SYSTEM-001")
    end

    it "membro che vede il progetto ma senza projects.edit → 403" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      create(:project_membership, account: member, project:)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      put "/cli/v1/projects/#{project.id}", headers: { "Authorization" => "Bearer #{member_secret}" },
                                            params: { name: "x" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "senza bearer → 401" do
      put "/cli/v1/projects/#{project.id}", params: { name: "x" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE destroy" do
    let!(:project) { create(:project, organization:) }

    it "owner elimina → 204 e progetto rimosso" do
      delete "/cli/v1/projects/#{project.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Projects::Project.exists?(project.id)).to be(false)
    end

    it "progetto di un'altra organizzazione → 404 (anti-BOLA)" do
      other = create(:project)

      delete "/cli/v1/projects/#{other.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "membro che vede il progetto ma senza projects.delete → 403" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      create(:project_membership, account: member, project:)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      delete "/cli/v1/projects/#{project.id}", headers: { "Authorization" => "Bearer #{member_secret}" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "senza bearer → 401 e progetto invariato" do
      delete "/cli/v1/projects/#{project.id}"

      expect(response).to have_http_status(:unauthorized)
      expect(Projects::Project.exists?(project.id)).to be(true)
    end
  end
end
