# frozen_string_literal: true

require "rails_helper"
require "msgpack"

RSpec.describe Crashes::Multipart do
  def parse_metadata(bytes, extra = [])
    parts = [ [ "__sentry-event", "__sentry-event", bytes ], [ "upload_file_minidump", "crash.dmp", "MDMP".b ] ] + extra
    wire = parts.map do |name, filename, value|
      disposition = "Content-Disposition: form-data; name=\"#{name}\""
      disposition += "; filename=\"#{filename}\"" if filename
      "--boundary\r\n#{disposition}\r\n\r\n".b + value.b + "\r\n".b
    end.join.b + "--boundary--\r\n".b
    described_class.call(body: StringIO.new(wire), content_type: "multipart/form-data; boundary=boundary")
  end

  it "preserves Crashpad identity and discards private event fields and the metadata attachment" do
    event = { "event_id" => "a" * 32, "release" => "native-1", "environment" => "test", "platform" => "native" }
    metadata, files = parse_metadata(MessagePack.pack(event.merge("user" => { "email" => "private@example.test" }, "extra" => { "token" => "private" })))
    expect(metadata).to eq(event)
    expect(files.map { |file| file[:header]["attachment_type"] }).to eq([ "event.minidump" ])
  end

  it "rejects ambiguous JSON and Crashpad metadata" do
    expect { parse_metadata(MessagePack.pack({ "release" => "one" }), [ [ "sentry", nil, { release: "two" }.to_json ] ]) }.to raise_error(Crashes::Rejected, "invalid_event_metadata")
  end

  it "rejects malformed, oversized, trailing and non-map MessagePack" do
    [ "", "x" * 65_537, "\xc1".b, MessagePack.pack([]), MessagePack.pack({}) + "x", "\xdf\xff\xff\xff\xff".b ].each do |bytes|
      expect { parse_metadata(bytes) }.to raise_error(Crashes::Rejected, "invalid_event_metadata")
    end
  end

  it "rejects duplicate metadata keys and invalid public values" do
    duplicate = "\x82".b + MessagePack.pack("release") + MessagePack.pack("one") + MessagePack.pack("release") + MessagePack.pack("two")
    expect { parse_metadata(duplicate) }.to raise_error(Crashes::Rejected, "invalid_event_metadata")
    [ 1, nil, [], "a\0b", "x" * 1025, "\xff".b ].each do |value|
      expect { parse_metadata(MessagePack.pack({ "release" => value })) }.to raise_error(Crashes::Rejected, "invalid_event_metadata")
    end
  end

  it "does not deserialize extension types through the application factory" do
    extension = "\x81\xa7release\xd4\x01x".b
    expect { parse_metadata(extension) }.to raise_error(Crashes::Rejected, "invalid_event_metadata")
  end

  it "bounds the root map and skips unrelated nested values" do
    values = (0...128).to_h { |index| [ "ignored#{index}", { "value" => [ 1, true, nil ] } ] }
    expect(parse_metadata(MessagePack.pack(values)).first).to eq({})
    expect { parse_metadata(MessagePack.pack(values.merge("extra" => 1))) }.to raise_error(Crashes::Rejected, "invalid_event_metadata")
    expect { parse_metadata(MessagePack.pack({ 1 => "value" })) }.to raise_error(Crashes::Rejected, "invalid_event_metadata")
  end

  it "does not discard an unrelated attachment that shares the metadata filename" do
    _, files = parse_metadata(MessagePack.pack({}), [ [ "other", "__sentry-event", "diagnostic" ] ])
    expect(files.map { |file| file[:bytes] }).to eq([ "MDMP", "diagnostic" ])
  end
end
