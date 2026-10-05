# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Stored artifact integrity" do
  [ [ Artifacts::NativeSymbols::Read, Artifacts::NativeSymbol, Artifacts::NativeSymbols::Processor::MAX_BINARY ],
    [ Artifacts::ProguardMaps::Read, Artifacts::ProguardMap, Artifacts::MAX_MAP ] ].each do |reader, model, limit|
    context reader.name do
      let(:bytes) { model == Artifacts::NativeSymbol ? File.binread(RbConfig.ruby) : Rails.root.join("spec/fixtures/artifacts/r8-9.4.28-mapping.txt").binread }
      let(:blob) do
        Artifacts::Blob.create!(project_id: create(:project).id, key: "artifacts/#{SecureRandom.hex(32)}", service_name: "test",
          byte_size: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes), reserved_until: 1.hour.from_now)
      end
      let(:artifact) { model.new(blob: blob) }
      after { blob.service.delete(blob.key) }

      it "reads actual stored bytes and detects byte-size and digest corruption" do
        blob.service.upload(blob.key, StringIO.new(bytes))
        expect(reader.call(artifact: artifact).b).to eq(bytes.b)
        blob.update!(byte_size: bytes.bytesize + 1)
        expect { reader.call(artifact: artifact) }.to raise_error(Artifacts::Unavailable, /integrity/)
        blob.update!(byte_size: bytes.bytesize, sha256: "0" * 64)
        expect { reader.call(artifact: artifact) }.to raise_error(Artifacts::Unavailable, /integrity/)
      end

      it "normalizes missing files to an unavailable result" do
        expect { reader.call(artifact: artifact) }.to raise_error(Artifacts::Unavailable, "Artifact is unavailable")
      end

      it "rejects oversized storage before trusting recorded blob metadata" do
        blob.service.upload(blob.key, StringIO.new("x" * (limit + 1)))
        expect { reader.call(artifact: artifact) }.to raise_error(Artifacts::Unavailable, /budget/)
      end
    end
  end
end
