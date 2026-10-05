# frozen_string_literal: true

require "rails_helper"

# Scaricare un file segreto: si decifra, si registra chi l'ha preso, si consegna. La parte che vale la
# pena presidiare è il rifiuto — un envelope manomesso o una chiave sbagliata devono dare un errore di
# dominio, e soprattutto NON devono lasciare nel registro una riga che dice «scaricato».
RSpec.describe Secrets::Assets::Download do
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
  let(:asset) do
    Secrets::Asset.create!(organization:, project:, name: "AuthKey", asset_type: "p8", created_by: actor)
  end
  let(:contenuto) { "-----BEGIN " + "PRIVATE KEY-----\nsegreto\n-----END PRIVATE KEY-----" }

  def upload(body = contenuto)
    file = Tempfile.new([ "AuthKey", ".p8" ])
    file.write(body)
    file.rewind
    uploaded = Rack::Test::UploadedFile.new(file.path, "application/octet-stream",
                                            original_filename: "AuthKey.p8")
    Secrets::Assets::Upload.call(asset:, uploaded_file: uploaded, actor:).value
  end

  it "restituisce il contenuto originale, byte per byte" do
    result = described_class.call(version: upload, actor:)

    expect(result).to be_ok
    expect(result.value).to eq(contenuto)
  end

  it "registra chi ha scaricato e quale versione" do
    version = upload

    expect { described_class.call(version:, actor:) }
      .to change { Secrets::AssetEvent.where(action: "downloaded").count }.by(1)

    event = Secrets::AssetEvent.where(action: "downloaded").last
    expect(event).to have_attributes(asset:, actor:, project:, organization:)
    expect(event.metadata).to eq({ "version" => version.number })
  end

  it "scaricare una versione vecchia dà il contenuto di allora" do
    prima = upload("-----BEGIN " + "PRIVATE KEY-----\nprima\n-----END PRIVATE KEY-----")
    upload("-----BEGIN " + "PRIVATE KEY-----\ndopo\n-----END PRIVATE KEY-----")

    expect(described_class.call(version: prima, actor:).value)
      .to eq("-----BEGIN " + "PRIVATE KEY-----\nprima\n-----END PRIVATE KEY-----")
  end

  it "un envelope manomesso è un errore di dominio e non lascia traccia di un download avvenuto" do
    version = upload
    Secrets::AssetVersion.where(id: version.id).update_all(payload_tag: Base64.strict_encode64("x" * 16))
    version.reload

    result = described_class.call(version:, actor:)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-SECRETFILE-005")
    expect(Secrets::AssetEvent.where(action: "downloaded")).not_to exist
  end

  # I dati che accompagnano il file entrano nel calcolo dell'integrità: cambiarli dopo la cifratura
  # rende il contenuto illeggibile invece di consegnarlo con un'etichetta falsa.
  it "cambiare i dati d'accompagnamento rende il file illeggibile invece di consegnarlo alterato" do
    version = upload
    Secrets::AssetVersion.where(id: version.id).update_all(original_filename: "altro.p8")
    version.reload

    expect(described_class.call(version:, actor:).error.code).to eq("R422-SECRETFILE-005")
  end

  it "con una chiave principale diversa il file non si apre" do
    version = upload
    ENV["SECRET_ASSETS_MASTER_KEY"] = Base64.strict_encode64("z" * 32)

    expect(described_class.call(version:, actor:)).to be_err
  end
end
