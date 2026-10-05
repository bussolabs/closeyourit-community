# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Projects::Github", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  describe "GET show" do
    it "senza bearer → 401" do
      get "/cli/v1/projects/#{project.id}/github"
      expect(response).to have_http_status(:unauthorized)
    end

    it "progetto senza repo → connected false, installed false" do
      get "/cli/v1/projects/#{project.id}/github", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["connected"]).to be(false)
      expect(data["installed"]).to be(false)
    end

    it "progetto con repo → connected true + regole" do
      create(:github_repository, project:, installation: create(:github_installation, organization:))

      get "/cli/v1/projects/#{project.id}/github", headers: headers

      data = response.parsed_body["data"]
      expect(data["connected"]).to be(true)
      expect(data["repository"]["tag_binding_enabled"]).to be(true)
    end

    it "progetto di un'altra org → 404 (anti-BOLA)" do
      other = create(:project)
      get "/cli/v1/projects/#{other.id}/github", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH update" do
    it "senza repo agganciato → 404 R404-GITHUB-002" do
      patch "/cli/v1/projects/#{project.id}/github", headers:, params: { tag_binding_enabled: false }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("R404-GITHUB-002")
    end

    it "toggla i flag booleani del repo agganciato" do
      repo = create(:github_repository, project:, installation: create(:github_installation, organization:))

      patch "/cli/v1/projects/#{project.id}/github", headers:, params: { tag_binding_enabled: false }

      expect(response).to have_http_status(:ok)
      expect(repo.reload.tag_binding_enabled).to be(false)
    end

    it "attiva sync_secrets e lo espone nel payload (CYCL-3)" do
      repo = create(:github_repository, project:, installation: create(:github_installation, organization:), sync_secrets: false)

      patch "/cli/v1/projects/#{project.id}/github", headers:, params: { sync_secrets: true }

      expect(response).to have_http_status(:ok)
      expect(repo.reload.sync_secrets).to be(true)
      expect(response.parsed_body["data"]["repository"]["sync_secrets"]).to be(true)
    end
  end

  describe "POST create" do
    let!(:installation) { create(:github_installation, organization:) }
    let(:available_repositories) do
      [ { "id" => 123, "full_name" => "bussolabs/closeyourit-agent", "default_branch" => "main" } ]
    end

    before do
      client = instance_double(Github::Client, repositories: available_repositories)
      allow(Github::Client).to receive(:new).and_return(client)
    end

    it "aggancia un repository disponibile risolvendone i metadati lato server" do
      post "/cli/v1/projects/#{project.id}/github", headers:, params: { full_name: "BUSSOLABS/CloseYourIt-Agent" }

      expect(response).to have_http_status(:created)
      expect(project.reload.github_repository).to have_attributes(
        repo_id: 123, full_name: "bussolabs/closeyourit-agent", default_branch: "main"
      )
      expect(response.parsed_body.dig("data", "connected")).to be(true)
    end

    it "rifiuta un repository non visibile all'installazione" do
      post "/cli/v1/projects/#{project.id}/github", headers:, params: { full_name: "other/private" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("R404-GITHUB-002")
      expect(project.reload.github_repository).to be_nil
    end

    it "propaga in modo strutturato gli errori del provider" do
      allow(Github::Client).to receive(:new).and_return(
        instance_double(Github::Client).tap do |client|
          allow(client).to receive(:repositories).and_raise(
            Github::Client::Error.new("GitHub timeout", code: "R502-GITHUB-001", status: :bad_gateway)
          )
        end
      )

      post "/cli/v1/projects/#{project.id}/github", headers:, params: { full_name: "bussolabs/closeyourit-agent" }

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body.dig("error", "code")).to eq("R502-GITHUB-001")
    end
  end

  # CYRA-234 — accendere sync_secrets abilita la copia dei valori del vault verso GitHub: è
  # un'impostazione a sé, non più un semplice feature-flag di binding. Richiede secrets.read; con
  # solo github.manage è rifiutata e il flag non cambia. Gli altri flag restano gestibili.
  describe "PATCH update — gate secrets.read su sync_secrets (CYRA-234)" do
    let(:restricted) { create(:account) }
    let(:restricted_headers) do
      token = Accounts::ApiTokens::Issue.call(account: restricted, organization:, name: "CLI").value[:secret]
      { "Authorization" => "Bearer #{token}" }
    end

    # `account` è già owner dell'org (before top-level): lo riuso come attore che concede l'override.
    before do
      create(:membership, account: restricted, organization:, role: :member)
      create(:project_membership, account: restricted, project:)
      Authorization::SetAccountPermissions.call(organization:, account: restricted,
                                                allow_keys: [ "github.manage" ], actor: account)
    end

    it "sync_secrets: true senza secrets.read → 403 e il flag NON cambia" do
      repo = create(:github_repository, project:, installation: create(:github_installation, organization:), sync_secrets: false)

      patch "/cli/v1/projects/#{project.id}/github", headers: restricted_headers, params: { sync_secrets: true }

      expect(response).to have_http_status(:forbidden)
      expect(repo.reload.sync_secrets).to be(false)
    end

    it "un altro flag (tag_binding_enabled) resta gestibile con solo github.manage → 200" do
      repo = create(:github_repository, project:, installation: create(:github_installation, organization:))

      patch "/cli/v1/projects/#{project.id}/github", headers: restricted_headers, params: { tag_binding_enabled: false }

      expect(response).to have_http_status(:ok)
      expect(repo.reload.tag_binding_enabled).to be(false)
    end
  end

  # CYRA-605 — la scelta su come si capisce che un rilascio è arrivato davvero passa dai due canali,
  # e in ognuno c'è un punto in cui può sparire in silenzio invece di dare errore.
  describe "release_probe dal canale CLI" do
    let!(:repository) { create(:github_repository, project:) }

    # Il buco peggiore: `settings_requested?` decide se tentare il salvataggio. Se non nomina il
    # campo nuovo, una richiesta col SOLO campo nuovo risponde 200 e non cambia niente — la
    # risposta dice che è andata bene e non è andata da nessuna parte.
    it "salva anche quando è l'unico campo della richiesta" do
      patch "/cli/v1/projects/#{project.id}/github", headers:, params: { release_probe: "merge" }

      expect(response).to have_http_status(:ok)
      expect(repository.reload.release_probe).to eq("merge")
    end

    it "torna nella lettura, e «non dichiarato» torna come niente" do
      get "/cli/v1/projects/#{project.id}/github", headers: headers
      expect(response.parsed_body.dig("data", "repository", "release_probe")).to be_nil

      # CYRA-625 — «il pacchetto è pubblicato» si salva insieme alle sue coordinate: senza, il
      # sistema non saprebbe su quale scaffale guardare né con che nome chiedere.
      repository.update!(release_probe: :publish, registry: :npm, package_name: "@closeyourit/cli")
      get "/cli/v1/projects/#{project.id}/github", headers: headers
      expect(response.parsed_body.dig("data", "repository", "release_probe")).to eq("publish")
    end

    it "un valore che non esiste è un 422, non un guasto del server" do
      patch "/cli/v1/projects/#{project.id}/github", headers:, params: { release_probe: "teletrasporto" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(repository.reload.release_probe).to be_nil
    end

    it "«il rilascio è in piedi» senza ambiente di produzione è un 422 con il motivo" do
      patch "/cli/v1/projects/#{project.id}/github", headers:, params: { release_probe: "deploy_smoke" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(repository.reload.release_probe).to be_nil
    end
  end
end
