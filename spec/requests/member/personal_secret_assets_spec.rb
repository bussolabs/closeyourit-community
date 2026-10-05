# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::PersonalSecretAssets", type: :request do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }

  around do |example|
    previous = ENV["SECRET_ASSETS_MASTER_KEY"]
    ENV["SECRET_ASSETS_MASTER_KEY"] = Base64.strict_encode64("k" * 32)
    example.run
  ensure
    ENV["SECRET_ASSETS_MASTER_KEY"] = previous
  end

  before { create(:membership, account:, organization:) }

  def sign_in(who = account)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  def key_upload(content: "ssh-private-key-bytes", filename: "id_rsa")
    file = Tempfile.new([ "key", File.extname(filename).presence || "" ])
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "application/octet-stream", original_filename: filename)
  end

  describe "index" do
    it "rende l'elenco per il proprietario (ungated) con la chip conteggi" do
      sign_in
      get member_personal_secret_assets_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="member-personal-secret-assets"')
      expect(response.body).to include('data-test="personal-secret-assets-counts"')
    end

    it "richiede l'autenticazione" do
      get member_personal_secret_assets_path
      expect(response).to have_http_status(:redirect)
    end
  end

  describe "upload + download (round-trip crypto)" do
    it "carica un file arbitrario e lo restituisce identico come attachment" do
      sign_in
      expect do
        post member_personal_secret_assets_path, params: { name: "id_rsa", file: key_upload(content: "SECRET-CONTENT-123") }
      end.to change { account.personal_secret_assets.count }.by(1)
      expect(response).to have_http_status(:see_other)

      asset = account.personal_secret_assets.last
      get download_member_personal_secret_asset_path(asset)
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("SECRET-CONTENT-123")
      expect(response.headers["Content-Disposition"]).to include("attachment")
    end

    it "rifiuta un file vuoto ripresentando il form" do
      sign_in
      post member_personal_secret_assets_path, params: { name: "empty", file: key_upload(content: "") }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('data-test="personal-secret-asset-form"')
    end
  end

  describe "versioni e rollback" do
    it "conserva le versioni e ripristina il contenuto di una precedente" do
      sign_in
      post member_personal_secret_assets_path, params: { name: "cfg", file: key_upload(content: "v1") }
      post member_personal_secret_assets_path, params: { name: "cfg", file: key_upload(content: "v2") }
      asset = account.personal_secret_assets.find_by(name: "cfg")
      expect(asset.versions.count).to eq(2)

      post rollback_member_personal_secret_asset_path(asset, version: 1)
      expect(asset.reload.versions.count).to eq(3)

      get download_member_personal_secret_asset_path(asset)
      expect(response.body).to eq("v1")
    end
  end

  describe "archivia e purge" do
    it "archivia (soft) e poi elimina definitivamente" do
      sign_in
      post member_personal_secret_assets_path, params: { name: "todel", file: key_upload(content: "x") }
      asset = account.personal_secret_assets.last

      delete member_personal_secret_asset_path(asset)
      expect(asset.reload.archived_at).to be_present

      expect do
        delete purge_member_personal_secret_asset_path(asset)
      end.to change { account.personal_secret_assets.count }.by(-1)
    end
  end

  describe "anti-BOLA" do
    it "nega l'accesso ai file di un altro account nella stessa org (404)" do
      other = create(:account)
      create(:membership, account: other, organization:)
      asset = create(:personal_secret_asset, account: other, organization:)

      sign_in
      get download_member_personal_secret_asset_path(asset)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "robustezza" do
    it "riattiva un file archiviato quando se ne ricarica uno con lo stesso nome" do
      sign_in
      post member_personal_secret_assets_path, params: { name: "cfg", file: key_upload(content: "v1") }
      asset = account.personal_secret_assets.find_by(name: "cfg")

      delete member_personal_secret_asset_path(asset)
      expect(asset.reload.archived_at).to be_present

      post member_personal_secret_assets_path, params: { name: "cfg", file: key_upload(content: "v2") }
      expect(response).to have_http_status(:see_other)
      expect(asset.reload.archived_at).to be_nil
      expect(account.personal_secret_assets.active.count).to eq(1)
    end

    it "gestisce con grazia un errore d'integrità nel rollback senza 500" do
      sign_in
      post member_personal_secret_assets_path, params: { name: "cfg", file: key_upload(content: "v1") }
      post member_personal_secret_assets_path, params: { name: "cfg", file: key_upload(content: "v2") }
      asset = account.personal_secret_assets.find_by(name: "cfg")

      allow(Secrets::Personal::Assets::Download).to receive(:call)
        .and_return(Result.err(AppError.new("integrità compromessa", code: "R422-PERSONALSECRETFILE-005")))

      post rollback_member_personal_secret_asset_path(asset, version: 1)
      expect(response).to have_http_status(:found)
      expect(response).to redirect_to(versions_member_personal_secret_asset_path(asset))
    end
  end

  # CYRA-422 — la protezione dei file personali sta nel corpo, non più nel suggerimento del titolo.
  describe "GET index — protezione nel corpo (CYRA-422)" do
    it "mostra la protezione dei file personali nel corpo, fuori dal tooltip del titolo" do
      sign_in
      get member_personal_secret_assets_path

      expect(response.body).to include('data-test="secret-protection"')
      expect(response.body).to include(I18n.t("member.secret_protection.encryption.personal_files"))
      expect(response.body).not_to include(I18n.t("member.personal_secret_assets.help_title"))
    end
  end
end
