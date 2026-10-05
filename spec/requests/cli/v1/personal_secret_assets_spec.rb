# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::PersonalSecretAssets", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  around do |example|
    previous = ENV["SECRET_ASSETS_MASTER_KEY"]
    ENV["SECRET_ASSETS_MASTER_KEY"] = Base64.strict_encode64("k" * 32)
    example.run
  ensure
    ENV["SECRET_ASSETS_MASTER_KEY"] = previous
  end

  before { create(:membership, account:, organization:) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  def key_upload(content: "bytes", filename: "id_rsa")
    file = Tempfile.new([ "key", File.extname(filename).presence || "" ])
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "application/octet-stream", original_filename: filename)
  end

  it "senza bearer → 401" do
    get "/cli/v1/personal_secret_assets"
    expect(response).to have_http_status(:unauthorized)
  end

  describe "GET index" do
    it "ritorna solo i miei file, coi metadati e MAI il ciphertext/envelope" do
      post "/cli/v1/personal_secret_assets", params: { name: "id_rsa", file: key_upload(content: "PRIVATE-BYTES") }, headers: headers
      expect(response).to have_http_status(:created)

      other = create(:account)
      create(:membership, account: other, organization:)
      create(:personal_secret_asset, account: other, organization:, name: "other")

      get "/cli/v1/personal_secret_assets", headers: headers
      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data.map { |asset| asset["name"] }).to contain_exactly("id_rsa")
      expect(response.body).not_to include("PRIVATE-BYTES")
      expect(data.first).not_to have_key("ciphertext")
      expect(data.first).not_to have_key("wrapped_key")
    end
  end

  describe "GET download" do
    it "restituisce il contenuto decifrato come attachment (per NAME)" do
      post "/cli/v1/personal_secret_assets", params: { name: "cfg", file: key_upload(content: "SECRET") }, headers: headers
      get "/cli/v1/personal_secret_assets/cfg/download", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("SECRET")
    end
  end

  describe "anti-BOLA" do
    it "nega i file di un altro account (404)" do
      other = create(:account)
      create(:membership, account: other, organization:)
      asset = create(:personal_secret_asset, account: other, organization:, name: "secret")

      get "/cli/v1/personal_secret_assets/#{asset.id}/download", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "nega storico, ripristino e cancellazione definitiva sui file di un altro account (404)" do
      other = create(:account)
      create(:membership, account: other, organization:)
      asset = create(:personal_secret_asset, account: other, organization:, name: "altrui", archived_at: Time.current)

      get "/cli/v1/personal_secret_assets/#{asset.id}/versions", headers: headers
      expect(response).to have_http_status(:not_found)

      post "/cli/v1/personal_secret_assets/#{asset.id}/rollback", params: { version: 1 }, headers: headers
      expect(response).to have_http_status(:not_found)

      delete "/cli/v1/personal_secret_assets/#{asset.id}/purge", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(Secrets::Personal::Asset.where(id: asset.id)).to exist
    end
  end

  describe "storico e ripristino" do
    it "elenca le versioni, ripristina quella scelta come nuova corrente e non stampa mai il contenuto" do
      post "/cli/v1/personal_secret_assets", params: { name: "cfg", file: key_upload(content: "PRIMA") }, headers: headers
      asset_id = response.parsed_body.dig("data", "id")
      post "/cli/v1/personal_secret_assets", params: { name: "cfg", file: key_upload(content: "DOPO") }, headers: headers

      get "/cli/v1/personal_secret_assets/#{asset_id}/versions", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |v| v["number"] }).to eq([ 2, 1 ])
      expect(response.body).not_to include("PRIMA")
      expect(response.body).not_to include("DOPO")

      post "/cli/v1/personal_secret_assets/#{asset_id}/rollback", params: { version: 1 }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "current_version", "number")).to eq(3)
      expect(response.body).not_to include("PRIMA")

      get "/cli/v1/personal_secret_assets/#{asset_id}/download", headers: headers
      expect(response.body).to eq("PRIMA")
      expect(Secrets::Personal::AssetEvent.where(action: "rolled_back", account:)).to exist
    end

    it "scarica una versione storica senza toccare la corrente" do
      post "/cli/v1/personal_secret_assets", params: { name: "cfg", file: key_upload(content: "V1") }, headers: headers
      asset_id = response.parsed_body.dig("data", "id")
      post "/cli/v1/personal_secret_assets", params: { name: "cfg", file: key_upload(content: "V2") }, headers: headers

      get "/cli/v1/personal_secret_assets/#{asset_id}/download", params: { version: 1 }, headers: headers
      expect(response.body).to eq("V1")
      get "/cli/v1/personal_secret_assets/#{asset_id}/download", headers: headers
      expect(response.body).to eq("V2")
    end

    it "risponde 404 su una versione inesistente" do
      post "/cli/v1/personal_secret_assets", params: { name: "cfg", file: key_upload }, headers: headers
      asset_id = response.parsed_body.dig("data", "id")

      post "/cli/v1/personal_secret_assets/#{asset_id}/rollback", params: { version: 9 }, headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE purge" do
    it "rifiuta la cancellazione definitiva finché il file non è archiviato" do
      post "/cli/v1/personal_secret_assets", params: { name: "vivo", file: key_upload }, headers: headers
      asset_id = response.parsed_body.dig("data", "id")

      delete "/cli/v1/personal_secret_assets/#{asset_id}/purge", headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-PERSONALSECRETFILE-007")
      expect(Secrets::Personal::Asset.where(id: asset_id)).to exist
    end

    it "elimina file e versioni dopo l'archiviazione, lasciando l'audit" do
      post "/cli/v1/personal_secret_assets", params: { name: "addio", file: key_upload }, headers: headers
      asset_id = response.parsed_body.dig("data", "id")

      delete "/cli/v1/personal_secret_assets/#{asset_id}", headers: headers
      delete "/cli/v1/personal_secret_assets/#{asset_id}/purge", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(Secrets::Personal::Asset.where(id: asset_id)).not_to exist
      expect(Secrets::Personal::AssetVersion.where(asset_id:)).not_to exist
      expect(Secrets::Personal::AssetEvent.where(action: "purged", account:)).to exist
    end

    it "l'elenco mostra anche gli archiviati, così il file da eliminare resta indirizzabile" do
      post "/cli/v1/personal_secret_assets", params: { name: "archiviato", file: key_upload }, headers: headers
      asset_id = response.parsed_body.dig("data", "id")
      delete "/cli/v1/personal_secret_assets/#{asset_id}", headers: headers

      get "/cli/v1/personal_secret_assets", headers: headers
      row = response.parsed_body["data"].find { |asset| asset["id"] == asset_id }
      expect(row).to be_present
      expect(row["archived_at"]).to be_present
    end
  end

  describe "deleghe" do
    it "non esistono sui file personali: solo i condivisi si delegano a un progetto" do
      post "/cli/v1/personal_secret_assets", params: { name: "mio", file: key_upload }, headers: headers
      asset_id = response.parsed_body.dig("data", "id")

      post "/cli/v1/personal_secret_assets/#{asset_id}/delegate", params: { project_id: SecureRandom.uuid }, headers: headers
      expect(response).to have_http_status(:not_found)

      delete "/cli/v1/personal_secret_assets/#{asset_id}/undelegate", params: { project_id: SecureRandom.uuid }, headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE" do
    it "archivia il file (soft)" do
      post "/cli/v1/personal_secret_assets", params: { name: "todel", file: key_upload }, headers: headers
      asset = Secrets::Personal::Asset.for(account:, organization:).find_by(name: "todel")

      delete "/cli/v1/personal_secret_assets/#{asset.id}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(asset.reload.archived_at).to be_present
    end
  end
end
