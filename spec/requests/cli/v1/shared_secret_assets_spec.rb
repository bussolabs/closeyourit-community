# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::SharedSecretAssets", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:headers) do
    token = Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{token}" }
  end

  around do |example|
    previous = ENV["SECRET_ASSETS_MASTER_KEY"]
    ENV["SECRET_ASSETS_MASTER_KEY"] = Base64.strict_encode64("k" * 32)
    example.run
  ensure
    ENV["SECRET_ASSETS_MASTER_KEY"] = previous
  end

  before { create(:membership, account:, organization:, role: :owner) }

  it "crea una sola copia condivisa e gestisce la delega al progetto" do
    post "/cli/v1/shared_secret_assets", headers: headers,
         params: { confirm: "1", name: "Distribution", file: p8_upload }
    expect(response).to have_http_status(:created)
    asset_id = response.parsed_body.dig("data", "id")

    get "/cli/v1/shared_secret_assets", headers: headers
    expect(response.parsed_body.dig("data", 0, "name")).to eq("Distribution")

    get "/cli/v1/shared_secret_assets/#{asset_id}/download", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("-----BEGIN " + "PRIVATE KEY-----\ntest-only\n-----END PRIVATE KEY-----")

    post "/cli/v1/shared_secret_assets/#{asset_id}/delegate", headers: headers, params: { confirm: "1", project_id: project.id }
    expect(response).to have_http_status(:created)
    expect(project.delegated_secret_assets.ids).to contain_exactly(asset_id)

    get "/cli/v1/projects/#{project.id}/secret_assets", headers: headers
    expect(response.parsed_body.dig("data", 0, "shared")).to be(true)

    delete "/cli/v1/shared_secret_assets/#{asset_id}/undelegate", headers: headers, params: { confirm: "1", project_id: project.id }
    expect(response).to have_http_status(:no_content)
    expect(project.delegated_secret_assets).to be_empty

    delete "/cli/v1/shared_secret_assets/#{asset_id}", params: { confirm: "1" }, headers: headers
    expect(response).to have_http_status(:no_content)
    expect(Secrets::Asset.find(asset_id)).to be_archived
  end

  it "rifiuta un environment estraneo" do
    post "/cli/v1/shared_secret_assets", headers: headers,
         params: { confirm: "1", name: "Bad env", environment: SecureRandom.uuid, file: p8_upload }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-SECRETFILE-006")
  end

  it "nega la gestione condivisa a un membro ordinario" do
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    token = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]
    get "/cli/v1/shared_secret_assets", headers: { "Authorization" => "Bearer #{token}" }
    expect(response).to have_http_status(:forbidden)
  end

  it "elenca le versioni, ripristina la scelta e scarica una versione storica" do
    post "/cli/v1/shared_secret_assets", headers: headers, params: { confirm: "1", name: "Lifecycle", file: p8_upload }
    asset_id = response.parsed_body.dig("data", "id")
    post "/cli/v1/shared_secret_assets", headers: headers, params: { confirm: "1", name: "Lifecycle", file: p8_upload(body: "-----BEGIN " + "PRIVATE KEY-----\nseconda\n-----END PRIVATE KEY-----") }

    get "/cli/v1/shared_secret_assets/#{asset_id}/versions", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"].map { |version| version["number"] }).to eq([ 2, 1 ])
    expect(response.body).not_to include("test-only")

    get "/cli/v1/shared_secret_assets/#{asset_id}/download", headers: headers, params: { version: 1 }
    expect(response.body).to eq("-----BEGIN " + "PRIVATE KEY-----\ntest-only\n-----END PRIVATE KEY-----")

    post "/cli/v1/shared_secret_assets/#{asset_id}/rollback", headers: headers, params: { confirm: "1", version: 1 }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "current_version", "number")).to eq(3)
    expect(response.body).not_to include("test-only")

    get "/cli/v1/shared_secret_assets/#{asset_id}/download", headers: headers
    expect(response.body).to eq("-----BEGIN " + "PRIVATE KEY-----\ntest-only\n-----END PRIVATE KEY-----")
    expect(Secrets::AssetEvent.where(action: "rolled_back", actor: account)).to exist
  end

  it "risponde 404 sul ripristino di una versione inesistente" do
    post "/cli/v1/shared_secret_assets", headers: headers, params: { name: "Solo una", file: p8_upload }
    asset_id = response.parsed_body.dig("data", "id")

    post "/cli/v1/shared_secret_assets/#{asset_id}/rollback", headers: headers, params: { version: 7 }
    expect(response).to have_http_status(:not_found)
  end

  it "elimina definitivamente solo dopo l'archiviazione" do
    post "/cli/v1/shared_secret_assets", headers: headers, params: { confirm: "1", name: "Addio", file: p8_upload }
    asset_id = response.parsed_body.dig("data", "id")

    delete "/cli/v1/shared_secret_assets/#{asset_id}/purge", params: { confirm: "1" }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-SECRETFILE-007")

    delete "/cli/v1/shared_secret_assets/#{asset_id}", params: { confirm: "1" }, headers: headers
    delete "/cli/v1/shared_secret_assets/#{asset_id}/purge", params: { confirm: "1" }, headers: headers
    expect(response).to have_http_status(:no_content)
    expect(Secrets::Asset.where(id: asset_id)).not_to exist
    expect(Secrets::AssetVersion.where(asset_id:)).not_to exist
    expect(Secrets::AssetEvent.where(action: "purged")).to exist
  end

  it "nega la cancellazione definitiva a chi gestisce i file condivisi ma non è owner" do
    manager = create(:account)
    create(:membership, account: manager, organization:, role: :member)
    manager.account_permissions.create!(organization:, permission_key: "shared_secret_files.manage", effect: "allow")
    manager_headers = { "Authorization" => "Bearer #{Accounts::ApiTokens::Issue.call(account: manager, organization:, name: 'CLI').value[:secret]}" }

    post "/cli/v1/shared_secret_assets", headers: headers, params: { confirm: "1", name: "Protetto", file: p8_upload }
    asset_id = response.parsed_body.dig("data", "id")

    post "/cli/v1/shared_secret_assets/#{asset_id}/rollback", headers: manager_headers, params: { confirm: "1", version: 1 }
    expect(response).to have_http_status(:ok)

    delete "/cli/v1/shared_secret_assets/#{asset_id}", params: { confirm: "1" }, headers: manager_headers
    delete "/cli/v1/shared_secret_assets/#{asset_id}/purge", params: { confirm: "1" }, headers: manager_headers
    expect(response).to have_http_status(:forbidden)
    expect(Secrets::Asset.where(id: asset_id)).to exist
  end

  it "nega storico, ripristino e cancellazione definitiva a un membro ordinario" do
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    member_headers = { "Authorization" => "Bearer #{Accounts::ApiTokens::Issue.call(account: member, organization:, name: 'CLI').value[:secret]}" }
    missing = SecureRandom.uuid

    get "/cli/v1/shared_secret_assets/#{missing}/versions", headers: member_headers
    expect(response).to have_http_status(:forbidden)

    post "/cli/v1/shared_secret_assets/#{missing}/rollback", headers: member_headers, params: { version: 1 }
    expect(response).to have_http_status(:forbidden)

    delete "/cli/v1/shared_secret_assets/#{missing}/purge", headers: member_headers
    expect(response).to have_http_status(:forbidden)
  end

  def p8_upload(body: "-----BEGIN " + "PRIVATE KEY-----\ntest-only\n-----END PRIVATE KEY-----")
    file = Tempfile.new([ "Distribution", ".p8" ])
    file.write(body)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "application/octet-stream", original_filename: "Distribution.p8")
  end
end
