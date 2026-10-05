# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Assets::Upload do
  around do |example|
    previous = ENV["SECRET_ASSETS_MASTER_KEY"]
    ENV["SECRET_ASSETS_MASTER_KEY"] = Base64.strict_encode64("k" * 32)
    example.run
  ensure
    ENV["SECRET_ASSETS_MASTER_KEY"] = previous
  end

  it "salva in ActiveStorage soltanto il ciphertext e permette il recupero" do
    project = create(:project)
    asset = Secrets::Asset.new(organization: project.organization, project:, name: "ASC key", asset_type: "p8")
    upload = uploaded("-----BEGIN PRIVATE KEY-----\ntest-only\n-----END PRIVATE KEY-----", "AuthKey_TEST.p8")

    result = described_class.call(asset:, uploaded_file: upload, actor: project.created_by)

    expect(result).to be_ok
    version = result.value
    expect(version.ciphertext.download).not_to include("PRIVATE KEY")
    expect(Secrets::Assets::Download.call(version:, actor: project.created_by).value).to include("test-only")
    expect(asset.versions.count).to eq(1)
  end

  it "rifiuta estensioni e contenuti non ammessi" do
    project = create(:project)
    asset = Secrets::Asset.new(organization: project.organization, project:, name: "Bad", asset_type: "p8")
    result = described_class.call(asset:, uploaded_file: uploaded("echo bad", "bad.sh"), actor: nil)
    expect(result).to be_err
    expect(asset).not_to be_persisted
  end

  it "rifiuta un p8 col contenuto incoerente e un upload assente" do
    project = create(:project)
    asset = Secrets::Asset.new(organization: project.organization, project:, name: "Bad", asset_type: "p8")
    expect(described_class.call(asset:, uploaded_file: uploaded("not-a-key", "bad.p8"), actor: nil)).to be_err
    expect(described_class.call(asset:, uploaded_file: nil, actor: nil)).to be_err
  end

  it "accetta JKS, JCEKS e service-account JSON validi" do
    project = create(:project)
    fixtures = [
      [ [ 0xFEEDFEED ].pack("N") + "test", "upload.jks" ],
      [ [ 0xCECECECE ].pack("N") + "test", "upload.keystore" ],
      [ { type: "service_account", project_id: "test", private_key: "test-only", client_email: "ci@example.test" }.to_json, "service.json" ]
    ]

    fixtures.each_with_index do |(bytes, filename), index|
      asset = Secrets::Asset.new(organization: project.organization, project:, name: "Asset #{index}", asset_type: "p8")
      expect(described_class.call(asset:, uploaded_file: uploaded(bytes, filename), actor: nil)).to be_ok
    end
  end

  it "rifiuta JSON incompleto e PKCS12 non ASN.1" do
    project = create(:project)
    json_asset = Secrets::Asset.new(organization: project.organization, project:, name: "JSON", asset_type: "p8")
    p12_asset = Secrets::Asset.new(organization: project.organization, project:, name: "P12", asset_type: "p8")
    expect(described_class.call(asset: json_asset, uploaded_file: uploaded('{"type":"service_account"}', "bad.json"), actor: nil)).to be_err
    expect(described_class.call(asset: p12_asset, uploaded_file: uploaded("not-asn1", "bad.p12"), actor: nil)).to be_err
  end

  def uploaded(bytes, filename)
    file = Tempfile.new
    file.binmode
    file.write(bytes)
    file.rewind
    ActionDispatch::Http::UploadedFile.new(tempfile: file, filename:, type: "application/octet-stream")
  end
end
