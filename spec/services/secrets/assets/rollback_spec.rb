# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Assets::Rollback do
  around do |example|
    previous = ENV["SECRET_ASSETS_MASTER_KEY"]
    ENV["SECRET_ASSETS_MASTER_KEY"] = Base64.strict_encode64("k" * 32)
    example.run
  ensure
    ENV["SECRET_ASSETS_MASTER_KEY"] = previous
  end

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:actor) { create(:account) }
  let(:asset) { Secrets::Asset.create!(organization:, project:, name: "AuthKey", asset_type: "p8", created_by: actor) }

  def upload(body)
    file = Tempfile.new([ "AuthKey", ".p8" ])
    file.write(body)
    file.rewind
    uploaded = Rack::Test::UploadedFile.new(file.path, "application/octet-stream", original_filename: "AuthKey.p8")
    Secrets::Assets::Upload.call(asset:, uploaded_file: uploaded, actor:).value
  end

  it "ricarica una versione precedente come nuova versione corrente e registra l'evento" do
    first = upload("-----BEGIN " + "PRIVATE KEY-----\nprima\n-----END PRIVATE KEY-----")
    upload("-----BEGIN " + "PRIVATE KEY-----\nseconda\n-----END PRIVATE KEY-----")

    result = described_class.call(source: first, actor:)

    expect(result).to be_ok
    expect(result.value.number).to eq(3)
    expect(Secrets::Assets::Download.call(version: result.value, actor:).value)
      .to eq("-----BEGIN " + "PRIVATE KEY-----\nprima\n-----END PRIVATE KEY-----")
    event = Secrets::AssetEvent.find_by(action: "rolled_back", asset:)
    expect(event.metadata).to include("from" => 1, "to" => 3)
  end

  it "propaga l'errore di integrità senza creare una nuova versione" do
    first = upload("-----BEGIN " + "PRIVATE KEY-----\nprima\n-----END PRIVATE KEY-----")
    Secrets::AssetVersion.where(id: first.id).update_all(payload_tag: Base64.strict_encode64("x" * 16))
    first.reload

    result = described_class.call(source: first, actor:)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-SECRETFILE-005")
    expect(asset.versions.count).to eq(1)
    expect(Secrets::AssetEvent.where(action: "rolled_back")).not_to exist
  end
end
