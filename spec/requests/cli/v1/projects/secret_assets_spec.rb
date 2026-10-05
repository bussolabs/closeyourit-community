# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Projects::SecretAssets", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:headers) { { "Authorization" => "Bearer #{Accounts::ApiTokens::Issue.call(account:, organization:, name: 'CLI').value[:secret]}" } }

  around do |example|
    previous = ENV["SECRET_ASSETS_MASTER_KEY"]
    ENV["SECRET_ASSETS_MASTER_KEY"] = Base64.strict_encode64("k" * 32)
    example.run
  ensure
    ENV["SECRET_ASSETS_MASTER_KEY"] = previous
  end

  before { create(:membership, account:, organization:, role: :owner) }

  it "carica, lista e scarica un file senza esporre il contenuto nei metadati" do
    post "/cli/v1/projects/#{project.id}/secret_assets", headers: headers, params: { confirm: "1", name: "ASC key", file: p8_upload }
    expect(response).to have_http_status(:created)
    asset_id = response.parsed_body.dig("data", "id")
    expect(response.body).not_to include("test-only")

    get "/cli/v1/projects/#{project.id}/secret_assets", headers: headers
    expect(response.parsed_body.dig("data", 0, "name")).to eq("ASC key")

    get "/cli/v1/projects/#{project.id}/secret_assets/#{asset_id}/download", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("-----BEGIN " + "PRIVATE KEY-----\ntest-only\n-----END PRIVATE KEY-----")
    expect(response.headers["Content-Disposition"]).to include("AuthKey_TEST.p8")
    expect(Secrets::AssetEvent.where(action: "downloaded", actor: account)).to exist
  end

  it "nega l'accesso a un membro senza i permessi dedicati" do
    restricted = create(:account)
    create(:membership, account: restricted, organization:, role: :member)
    create(:project_membership, account: restricted, project:)
    token = Accounts::ApiTokens::Issue.call(account: restricted, organization:, name: "CLI").value[:secret]
    get "/cli/v1/projects/#{project.id}/secret_assets", headers: { "Authorization" => "Bearer #{token}" }
    expect(response).to have_http_status(:forbidden)
  end

  it "nega ogni azione a un membro con accesso base ma senza permessi sui file segreti" do
    restricted = create(:account)
    create(:membership, account: restricted, organization:, role: :member)
    create(:project_membership, account: restricted, project:)
    token = Accounts::ApiTokens::Issue.call(account: restricted, organization:, name: "CLI").value[:secret]
    restricted_headers = { "Authorization" => "Bearer #{token}" }
    missing = SecureRandom.uuid
    base = "/cli/v1/projects/#{project.id}/secret_assets"

    post base, headers: restricted_headers, params: { name: "X", file: p8_upload }
    expect(response).to have_http_status(:forbidden) # create → require_manage

    get "#{base}/#{missing}/download", headers: restricted_headers
    expect(response).to have_http_status(:forbidden) # download → require_read

    get "#{base}/#{missing}/versions", headers: restricted_headers
    expect(response).to have_http_status(:forbidden) # versions → require_read

    post "#{base}/#{missing}/rollback", headers: restricted_headers, params: { version: 1 }
    expect(response).to have_http_status(:forbidden) # rollback → require_manage

    delete "#{base}/#{missing}", headers: restricted_headers
    expect(response).to have_http_status(:forbidden) # destroy → require_manage

    delete "#{base}/#{missing}/purge", headers: restricted_headers
    expect(response).to have_http_status(:forbidden) # purge → require_owner
  end

  it "gestisce versioni, rollback, archiviazione e purge con i relativi vincoli" do
    post "/cli/v1/projects/#{project.id}/secret_assets", headers:, params: { confirm: "1", name: "Lifecycle", file: p8_upload }
    asset_id = response.parsed_body.dig("data", "id")

    get "/cli/v1/projects/#{project.id}/secret_assets/#{asset_id}/versions", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", 0, "number")).to eq(1)

    get "/cli/v1/projects/#{project.id}/secret_assets/#{asset_id}/download", headers:, params: { version: 1 }
    expect(response).to have_http_status(:ok)

    post "/cli/v1/projects/#{project.id}/secret_assets/#{asset_id}/rollback", headers:, params: { confirm: "1", version: 1 }
    expect(response).to have_http_status(:ok)
    expect(Secrets::Asset.find(asset_id).versions.pluck(:number)).to contain_exactly(1, 2)

    delete "/cli/v1/projects/#{project.id}/secret_assets/#{asset_id}/purge", params: { confirm: "1" }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)

    delete "/cli/v1/projects/#{project.id}/secret_assets/#{asset_id}", params: { confirm: "1" }, headers: headers
    expect(response).to have_http_status(:no_content)
    delete "/cli/v1/projects/#{project.id}/secret_assets/#{asset_id}/purge", params: { confirm: "1" }, headers: headers
    expect(response).to have_http_status(:no_content)
    expect(Secrets::Asset.where(id: asset_id)).not_to exist
  end

  it "rifiuta environment estranei e propaga gli errori di validazione dell'upload" do
    foreign_environment = create(:environment, organization: create(:organization))
    post "/cli/v1/projects/#{project.id}/secret_assets", headers:,
         params: { name: "Wrong env", environment: foreign_environment.id, file: p8_upload }
    expect(response).to have_http_status(:unprocessable_content)

    post "/cli/v1/projects/#{project.id}/secret_assets", headers:,
         params: { name: "Invalid", file: invalid_p8_upload }
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "associa l'asset a un environment dichiarato dal progetto" do
    environment = create(:environment, organization:)
    create(:project_environment, project:, environment:)

    post "/cli/v1/projects/#{project.id}/secret_assets", headers:,
         params: { confirm: "1", name: "Scoped", environment: environment.id, file: p8_upload }

    expect(response).to have_http_status(:created)
    expect(project.secret_assets.last.environment_id).to eq(environment.id)
  end

  # Restrizione ambiente sui file-segreto (CYRA-268): un service account confinato a "staging" non
  # può toccare i file di "production", nemmeno chiamandoli per identificativo (il buco originale).
  context "service account ristretto a staging" do
    let(:staging)    { create(:environment, organization:, code: "staging").tap { |e| project.environments << e } }
    let(:production) { create(:environment, organization:, code: "production").tap { |e| project.environments << e } }
    let(:bot) do
      account = Accounts::Service::Create.call(
        organization:, name: "Staging Bot", project_ids: [ project.id ], secret_environment_codes: [ "staging" ]
      ).value
      %w[secret_files.read secret_files.manage].each do |key|
        account.account_permissions.create!(organization:, permission_key: key, effect: "allow")
      end
      account
    end
    let(:bot_headers) { { "Authorization" => "Bearer #{Accounts::ApiTokens::Issue.call(account: bot, organization:, name: 'CLI').value[:secret]}" } }

    # Gli environment devono esistere PRIMA di creare `bot`: Service::Create scarta i code inesistenti
    # (sanitized_environment_codes), quindi senza questo la restrizione andrebbe persa in silenzio.
    before { staging && production }

    # Asset di production e staging creati dall'owner (non ristretto).
    let(:prod_asset_id) do
      post "/cli/v1/projects/#{project.id}/secret_assets", headers:, params: { confirm: "1", name: "PRD", environment: production.id, file: p8_upload }
      response.parsed_body.dig("data", "id")
    end
    let(:stg_asset_id) do
      post "/cli/v1/projects/#{project.id}/secret_assets", headers:, params: { confirm: "1", name: "STG", environment: staging.id, file: p8_upload }
      response.parsed_body.dig("data", "id")
    end

    it "scarica un file dell'ambiente consentito → 200" do
      get "/cli/v1/projects/#{project.id}/secret_assets/#{stg_asset_id}/download", headers: bot_headers
      expect(response).to have_http_status(:ok)
    end

    it "NEGA lo scarico di un file di production per identificativo → 403 R403-SECRETFILE-001" do
      get "/cli/v1/projects/#{project.id}/secret_assets/#{prod_asset_id}/download", headers: bot_headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-SECRETFILE-001")
    end

    # CYRA-666 — anche da terminale il tentativo lascia traccia, col canale nei metadata: una lettura
    # dal terminale e una dal browser non pesano uguale per chi indaga.
    it "il tentativo negato lascia un evento denied col canale cli" do
      expect do
        get "/cli/v1/projects/#{project.id}/secret_assets/#{prod_asset_id}/download", headers: bot_headers
      end.to change { Secrets::AssetEvent.where(action: "denied").count }.by(1)

      event = Secrets::AssetEvent.where(action: "denied").last
      expect(event.asset_id).to eq(prod_asset_id)
      expect(event.project).to eq(project)
      expect(event.metadata["channel"]).to eq("cli")
    end

    it "NEGA rollback e cancellazione di un file di production → 403" do
      post "/cli/v1/projects/#{project.id}/secret_assets/#{prod_asset_id}/rollback", headers: bot_headers, params: { confirm: "1", version: 1 }
      expect(response).to have_http_status(:forbidden)

      delete "/cli/v1/projects/#{project.id}/secret_assets/#{prod_asset_id}", params: { confirm: "1" }, headers: bot_headers
      expect(response).to have_http_status(:forbidden)
    end

    it "crea un file su staging → 201, su production → 403" do
      post "/cli/v1/projects/#{project.id}/secret_assets", headers: bot_headers, params: { confirm: "1", name: "New STG", environment: staging.id, file: p8_upload }
      expect(response).to have_http_status(:created)

      post "/cli/v1/projects/#{project.id}/secret_assets", headers: bot_headers, params: { confirm: "1", name: "New PRD", environment: production.id, file: p8_upload }
      expect(response).to have_http_status(:forbidden)
    end

    it "l'elenco nasconde i file degli ambienti vietati" do
      prod_asset_id && stg_asset_id
      get "/cli/v1/projects/#{project.id}/secret_assets", headers: bot_headers
      names = response.parsed_body["data"].map { |r| r["name"] }
      expect(names).to include("STG")
      expect(names).not_to include("PRD")
    end
  end

  def p8_upload
    file = Tempfile.new([ "AuthKey_TEST", ".p8" ])
    file.write("-----BEGIN " + "PRIVATE KEY-----\ntest-only\n-----END PRIVATE KEY-----")
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "application/octet-stream", original_filename: "AuthKey_TEST.p8")
  end

  def invalid_p8_upload
    file = Tempfile.new([ "invalid", ".p8" ])
    file.write("not a private key")
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "application/octet-stream", original_filename: "invalid.p8")
  end
end
