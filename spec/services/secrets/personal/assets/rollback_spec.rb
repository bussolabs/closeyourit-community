# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Personal::Assets::Rollback do
  around do |example|
    previous = ENV["SECRET_ASSETS_MASTER_KEY"]
    ENV["SECRET_ASSETS_MASTER_KEY"] = Base64.strict_encode64("k" * 32)
    example.run
  ensure
    ENV["SECRET_ASSETS_MASTER_KEY"] = previous
  end

  let(:asset) { create(:personal_secret_asset) }

  def upload(body)
    file = Tempfile.new("id_rsa")
    file.write(body)
    file.rewind
    uploaded = Rack::Test::UploadedFile.new(file.path, "application/octet-stream", original_filename: "id_rsa")
    Secrets::Personal::Assets::Upload.call(asset:, uploaded_file: uploaded).value
  end

  it "ricarica una versione precedente come nuova versione corrente e registra l'evento" do
    first = upload("PRIMA")
    upload("DOPO")

    result = described_class.call(source: first)

    expect(result).to be_ok
    expect(result.value.number).to eq(3)
    expect(Secrets::Personal::Assets::Download.call(version: result.value).value).to eq("PRIMA")
    event = Secrets::Personal::AssetEvent.find_by(action: "rolled_back", asset:)
    expect(event.metadata).to include("from" => 1, "to" => 3)
  end

  it "propaga l'errore di integrità senza creare una nuova versione" do
    first = upload("PRIMA")
    Secrets::Personal::AssetVersion.where(id: first.id).update_all(payload_tag: Base64.strict_encode64("x" * 16))
    first.reload

    result = described_class.call(source: first)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-PERSONALSECRETFILE-005")
    expect(asset.versions.count).to eq(1)
    expect(Secrets::Personal::AssetEvent.where(action: "rolled_back")).not_to exist
  end
end
