# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Personal::Assets::Upload do
  around do |example|
    previous = ENV["SECRET_ASSETS_MASTER_KEY"]
    ENV["SECRET_ASSETS_MASTER_KEY"] = Base64.strict_encode64("k" * 32)
    example.run
  ensure
    ENV["SECRET_ASSETS_MASTER_KEY"] = previous
  end

  let(:asset) { create(:personal_secret_asset) }

  # Upload finto che dichiara una dimensione ma esplode se qualcuno prova a leggerne il contenuto: verifica
  # che la guardia sul cap scatti PRIMA di caricare il file in memoria.
  def oversized_upload(size:)
    upload = Object.new
    upload.define_singleton_method(:size) { size }
    upload.define_singleton_method(:original_filename) { "big.bin" }
    upload.define_singleton_method(:content_type) { "application/octet-stream" }
    upload.define_singleton_method(:read) { raise "read non deve essere chiamato per un file oltre il cap" }
    upload.define_singleton_method(:rewind) { nil }
    upload
  end

  it "rifiuta un file oltre il cap SENZA leggerne il contenuto in memoria (anti-DoS)" do
    result = described_class.call(asset:, uploaded_file: oversized_upload(size: 11.megabytes))
    expect(result).to be_err
    expect(result.error.code).to eq("R422-PERSONALSECRETFILE-002")
  end

  it "cifra e versiona un file valido, decifrabile dal servizio Download (round-trip)" do
    file = Tempfile.new("k")
    file.write("SECRET-BYTES")
    file.rewind
    upload = Rack::Test::UploadedFile.new(file.path, "application/octet-stream", original_filename: "id_rsa")

    result = described_class.call(asset:, uploaded_file: upload)
    expect(result).to be_ok
    expect(asset.reload.asset_type).to eq("file")

    download = Secrets::Personal::Assets::Download.call(version: result.value)
    expect(download.value).to eq("SECRET-BYTES")
  end
end
