# frozen_string_literal: true

require "rails_helper"

# Gemello personale dello scarico di un file segreto: stesso impianto, codice d'errore proprio e
# nessun attore da passare — il vault personale ha un solo proprietario.
RSpec.describe Secrets::Personal::Assets::Download do
  around do |example|
    previous = ENV["SECRET_ASSETS_MASTER_KEY"]
    ENV["SECRET_ASSETS_MASTER_KEY"] = Base64.strict_encode64("k" * 32)
    example.run
  ensure
    ENV["SECRET_ASSETS_MASTER_KEY"] = previous
  end

  let(:asset) { create(:personal_secret_asset, name: "id_rsa") }

  def upload(body = "chiave-privata")
    file = Tempfile.new("id_rsa")
    file.write(body)
    file.rewind
    uploaded = Rack::Test::UploadedFile.new(file.path, "application/octet-stream",
                                            original_filename: "id_rsa")
    Secrets::Personal::Assets::Upload.call(asset:, uploaded_file: uploaded).value
  end

  it "restituisce il contenuto originale" do
    result = described_class.call(version: upload)

    expect(result).to be_ok
    expect(result.value).to eq("chiave-privata")
  end

  it "registra il download col numero di versione e col nome del file" do
    version = upload

    expect { described_class.call(version:) }
      .to change { Secrets::Personal::AssetEvent.where(action: "downloaded").count }.by(1)

    event = Secrets::Personal::AssetEvent.where(action: "downloaded").last
    expect(event).to have_attributes(asset:, account: asset.account, organization: asset.organization)
    expect(event.metadata).to include("version" => version.number, "name" => "id_rsa")
  end

  it "scaricare una versione vecchia dà il contenuto di allora" do
    prima = upload("prima")
    upload("dopo")

    expect(described_class.call(version: prima).value).to eq("prima")
  end

  it "un envelope manomesso è un errore di dominio e non lascia traccia di un download avvenuto" do
    version = upload
    Secrets::Personal::AssetVersion.where(id: version.id)
                                   .update_all(payload_tag: Base64.strict_encode64("x" * 16))
    version.reload

    result = described_class.call(version:)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-PERSONALSECRETFILE-005")
    expect(Secrets::Personal::AssetEvent.where(action: "downloaded")).not_to exist
  end

  it "con una chiave principale diversa il file non si apre" do
    version = upload
    ENV["SECRET_ASSETS_MASTER_KEY"] = Base64.strict_encode64("z" * 32)

    expect(described_class.call(version:)).to be_err
  end
end
