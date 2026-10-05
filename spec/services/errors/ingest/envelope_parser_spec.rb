# frozen_string_literal: true

require "rails_helper"
require "stringio"
require "zlib"

RSpec.describe Errors::Ingest::EnvelopeParser, type: :service do
  def envelope(*lines) = (lines.map { |l| l.is_a?(String) ? l : l.to_json }.join("\n") + "\n")

  def gzip(str)
    io = StringIO.new
    gz = Zlib::GzipWriter.new(io)
    gz.write(str)
    gz.close
    io.string
  end

  let(:event) { { "event_id" => "abc123", "level" => "error", "message" => "boom" } }

  it "estrae l'item event da un envelope newline-delimited" do
    body = envelope({ "event_id" => "abc123" }, { "type" => "event" }, event)
    result = described_class.call(body: body)
    expect(result).to be_ok
    expect(result.value).to eq([ event ])
  end

  it "supporta gli item length-prefixed" do
    payload = event.to_json
    body = "#{ { 'event_id' => 'abc123' }.to_json }\n" \
           "#{ { 'type' => 'event', 'length' => payload.bytesize }.to_json }\n" \
           "#{payload}\n"
    expect(described_class.call(body: body).value).to eq([ event ])
  end

  it "decodifica un envelope gzip" do
    body = gzip(envelope({ "event_id" => "abc123" }, { "type" => "event" }, event))
    expect(described_class.call(body: body).value).to eq([ event ])
  end

  it "ignores unsupported transaction items" do
    body = envelope(
      { "event_id" => "abc123" },
      { "type" => "transaction" }, { "sid" => "s1" },
      { "type" => "event" }, event
    )
    expect(described_class.call(body: body).value).to eq([ event ])
  end

  it "envelope senza item event → lista vuota" do
    body = envelope({ "event_id" => "abc123" }, { "type" => "transaction" }, { "sid" => "s1" })
    expect(described_class.call(body: body).value).to eq([])
  end

  it "rejects event items with an empty payload" do
    body = "#{ { 'event_id' => 'x' }.to_json }\n#{ { 'type' => 'event' }.to_json }\n\n"
    expect(described_class.call(body: body)).to be_err
  end

  it "payload compresso oltre il limite → R413" do
    big = described_class.const_get(:MAX_COMPRESSED) + 1
    result = described_class.call(body: "x" * big)
    expect(result).to be_err
    expect(result.error.code).to eq("R413-INGEST-001")
    expect(result.error.status).to eq(:content_too_large)
  end

  it "gzip-bomb: decompresso oltre il limite → R413" do
    huge = "A" * (described_class.const_get(:MAX_DECOMPRESSED) + 100)
    body = gzip(envelope({ "event_id" => "x" }, { "type" => "event" }, { "blob" => huge }))
    result = described_class.call(body: body)
    expect(result).to be_err
    expect(result.error.code).to eq("R413-INGEST-001")
  end

  it "JSON malformato → R422" do
    result = described_class.call(body: "{not json\n{\"type\":\"event\"}\n{}\n")
    expect(result).to be_err
    expect(result.error.code).to eq("R422-INGEST-001")
  end

  it "salta le righe vuote tra gli item (next su header_line blank)" do
    body = envelope({ "event_id" => event["event_id"] }, "", { "type" => "event" }, event)
    expect(described_class.call(body: body).value).to eq([ event ])
  end

  it "rejects event items without a payload at end of stream" do
    body = envelope({ "event_id" => "x" }, { "type" => "event" })
    expect(described_class.call(body: body)).to be_err
  end

  describe ".gunzip_limited" do
    it "da un gzip enorme legge al più max+1 byte: non decomprime mai l'intero stream (anti-bomb)" do
      bomb = gzip("A" * 50.megabytes) # 50MB di byte ripetuti → decine di KB compressi
      out = described_class.gunzip_limited(bomb, described_class::MAX_DECOMPRESSED)
      expect(out.bytesize).to eq(described_class::MAX_DECOMPRESSED + 1)
    end

    it "restituisce i byte inalterati quando non sono gzip" do
      expect(described_class.gunzip_limited("testo in chiaro".b, 1_000)).to eq("testo in chiaro")
    end
  end

  it "gzip-bomb da 50MB: R413 senza mai tenere in memoria più di MAX_DECOMPRESSED+1 byte" do
    bomb = gzip(envelope({ "event_id" => "x" }, { "type" => "event" }, { "blob" => "A" * 50.megabytes }))
    expect(bomb.bytesize).to be < described_class::MAX_COMPRESSED # supera il primo gate compresso

    sizes = []
    allow(described_class).to receive(:gunzip_limited).and_wrap_original do |orig, *args|
      orig.call(*args).tap { |out| sizes << out.bytesize }
    end

    result = described_class.call(body: bomb)
    expect(result).to be_err
    expect(result.error.code).to eq("R413-INGEST-001")
    expect(sizes).to all(be <= described_class::MAX_DECOMPRESSED + 1)
  end
end
