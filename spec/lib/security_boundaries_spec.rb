# frozen_string_literal: true

require "rails_helper"
require "net/http"

RSpec.describe "Resource and delivery security boundaries" do
  describe NetworkGuard do
    %w[::ffff:127.0.0.1 ::ffff:10.0.0.1 ::ffff:169.254.169.254 ::127.0.0.1 :: ff02::1 224.0.0.1].each do |address|
      it "blocks #{address} before opening a connection" do
        expect(NetworkGuard.resolved_public_address(address)).to be_nil
      end
    end

    it "accepts a mapped public address" do
      expect(NetworkGuard.resolved_public_address("::ffff:1.1.1.1")).to eq("::ffff:1.1.1.1")
    end
  end

  describe BoundedHttp do
    let(:uri) { URI("https://example.test/resource") }
    let(:http) { Net::HTTP.new(uri.host, uri.port).tap { |client| client.use_ssl = true } }

    it "preserves a response at the byte boundary" do
      stub_request(:get, uri.to_s).to_return(body: "test")
      response = described_class.request(http, Net::HTTP::Get.new(uri), max_bytes: 4, timeout: 1)
      expect(response.body).to eq("test")
    end

    it "rejects an oversized response" do
      stub_request(:get, uri.to_s).to_return(body: "tests")
      expect { described_class.request(http, Net::HTTP::Get.new(uri), max_bytes: 4, timeout: 1) }
        .to raise_error(BoundedHttp::ResponseTooLarge)
    end
  end

  describe Errors::Ingest::EnvelopeParser do
    def envelope_items(type, count)
      "{}\n" + ("#{ { type: type }.to_json }\n#{ { message: 'test' }.to_json }\n" * count)
    end

    it "accepts fifty events without a shared envelope identifier" do
      expect(described_class.call(body: envelope_items("event", 50)).value.size).to eq(50)
    end

    it "rejects the fifty-first event before enqueueing any jobs" do
      expect(described_class.call(body: envelope_items("event", 51)).error.code).to eq("R413-INGEST-001")
    end

    it "accepts one hundred ignored items" do
      expect(described_class.call(body: envelope_items("future-item", 100))).to be_ok
    end

    it "bounds ignored items as well as events" do
      expect(described_class.call(body: envelope_items("future-item", 101)).error.code).to eq("R413-INGEST-001")
    end
  end

  describe Replays::Read do
    def attachment(seq, content)
      raw = ActiveSupport::Gzip.compress(content)
      blob = double(filename: "session-#{seq}.json.gz", byte_size: raw.bytesize)
      allow(blob).to receive(:download).and_yield(raw)
      double(blob: blob)
    end

    def playback(attachments)
      relation = double
      allow(relation).to receive(:includes).with(:blob).and_return(relation)
      allow(relation).to receive(:limit).with(Replays::Constants::SESSION_MAX_CHUNKS + 1).and_return(attachments)
      described_class.call(session: double(chunks: relation))
    end

    it "returns an empty stream for zero chunks" do
      expect(playback([]).value).to eq([])
    end

    it "sorts chunks by sequence before joining their events" do
      expect(playback([ attachment(1, '[2]'), attachment(0, '[1]') ]).value).to eq([ 1, 2 ])
    end

    it "rejects an oversized legacy session without downloading any blob" do
      item = attachment(0, '[]')
      expect(item.blob).not_to receive(:download)
      expect(playback([ item ] * 121).error.code).to eq("R413-REPLAY-003")
    end

    it "bounds decompression before parsing the expanded payload" do
      bomb = attachment(0, '"' + 'x' * Replays::Constants::CHUNK_MAX_DECOMPRESSED_BYTES + '"')
      expect(playback([ bomb ]).error.code).to eq("R413-REPLAY-003")
    end

    it "rejects too many events even inside a small compressed chunk" do
      item = attachment(0, Array.new(Replays::Constants::SESSION_MAX_EVENTS + 1, 0).to_json)
      expect(playback([ item ]).error.code).to eq("R413-REPLAY-003")
    end
  end

  describe "Dataset image budgets" do
    it "downloads only the first six matching images for prediction and training" do
      columns = (1..7).map { |id| double(id: id, kind_photo?: true) }
      cells = columns.map do |column|
        image = double(attached?: true, content_type: "image/png")
        if column.id <= 6
          expect(image).to receive(:download).twice.and_return("test")
        else
          expect(image).not_to receive(:download)
        end
        double(column_id: column.id, image: image)
      end
      row = double(cells: cells)
      predictor = Datasets::Ai::Predict.new(system_prompt: "test", row: row, input_columns: columns, target_columns: [])
      builder = Datasets::Ai::BuildPrompt.new(dataset: nil, examples: [ row ], input_columns: columns, target_columns: [])
      expect(predictor.send(:image_parts).size).to eq(6)
      expect(builder.send(:example_images).size).to eq(6)
    end
  end

  describe Realtime::AuthorizedStreams do
    let(:channel) do
      Class.new do
        include Realtime::AuthorizedStreams
        attr_accessor :connection
      end.new
    end
    let(:account) { double(id: "account") }
    let(:organization) { double(id: "org") }
    let(:connection) { double(live_account: account, current_organization: organization) }

    before { allow(channel).to receive(:connection).and_return(connection) }

    it "rejects delivery after the session or membership is revoked" do
      allow(connection).to receive(:live_account).and_return(nil)
      expect(channel.send(:authorized_stream?, "org:org:chat:conversation:chat")).to be(false)
    end

    it "rejects a signed stream from a different organization" do
      expect(channel.send(:authorized_stream?, "org:other:errors")).to be(false)
    end

    it "rechecks conversation access on every delivery" do
      conversation = double
      allow(Chat::Conversation).to receive(:find_by).with(id: "chat", organization_id: "org").and_return(conversation)
      allow(conversation).to receive(:accessible_by?).with(account).and_return(true, false)
      expect(channel.send(:authorized_stream?, "org:org:chat:conversation:chat")).to be(true)
      expect(channel.send(:authorized_stream?, "org:org:chat:conversation:chat")).to be(false)
    end
  end
end
