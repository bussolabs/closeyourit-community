# frozen_string_literal: true

require "rails_helper"

RSpec.describe Crashes::Multipart do
  def multipart(dump, metadata = { release: "v1" }.to_json)
    "--boundary\r\nContent-Disposition: form-data; name=\"sentry\"\r\n\r\n#{metadata}\r\n--boundary\r\nContent-Disposition: form-data; name=\"upload_file_minidump\"; filename=\"crash.dmp\"\r\nContent-Type: application/octet-stream\r\n\r\n".b + dump + "\r\n--boundary--\r\n".b
  end

  it "parses bounded multipart binary bytes in memory and keeps only event metadata" do
    bytes = "\x00\xff\n\r\n".b
    body = multipart(bytes, { release: "v1", user: { email: "private@example.test" }, extra: { password: "private" } }.to_json)
    event, items = described_class.call(body: StringIO.new(body), content_type: "multipart/form-data; boundary=boundary")
    expect(event).to eq("release" => "v1")
    expect(items.sole[:bytes]).to eq(bytes)
    expect(items.sole[:header]).to include("attachment_type" => "event.minidump")
  end

  it "accepts HTTP gzip and rejects truncated multipart bodies" do
    body = multipart("MDMP".b)
    compressed = StringIO.new
    Zlib::GzipWriter.wrap(compressed) { |writer| writer.write(body) }
    expect(described_class.call(body: StringIO.new(compressed.string), content_type: "multipart/form-data; boundary=boundary").last.sole[:bytes]).to eq("MDMP")
    expect { described_class.call(body: StringIO.new(body.byteslice(0, body.bytesize - 20)), content_type: "multipart/form-data; boundary=boundary") }.to raise_error(Crashes::Rejected, "invalid_multipart")
  end

  it "requires a minidump and rejects malformed or overlarge metadata" do
    expect { described_class.call(body: StringIO.new(multipart("x", "[1]")), content_type: "multipart/form-data; boundary=boundary") }.to raise_error(Crashes::Rejected, "invalid_event_metadata")
    expect { described_class.call(body: StringIO.new(multipart("x", "x" * 65537)), content_type: "multipart/form-data; boundary=boundary") }.to raise_error(Crashes::Rejected, "invalid_event_metadata")
  end
end
