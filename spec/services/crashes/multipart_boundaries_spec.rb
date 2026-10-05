# frozen_string_literal: true

require "rails_helper"

RSpec.describe Crashes::Multipart do
  def parse(parts)
    wire = parts.map do |name, filename, value|
      disposition = "Content-Disposition: form-data; name=\"#{name}\""
      disposition += "; filename=\"#{filename}\"" if filename
      "--boundary\r\n#{disposition}\r\n\r\n#{value}\r\n"
    end.join + "--boundary--\r\n"
    described_class.call(body: StringIO.new(wire), content_type: "multipart/form-data; boundary=boundary")
  end

  it "accepts absent metadata and separates attachments from the minidump" do
    event, files = parse([ [ "upload_file_minidump", "crash.dmp", "MDMP" ], [ "diagnostic", "note.txt", "bounded note" ], [ "ignored", nil, "value" ] ])
    expect(event).to eq({})
    expect(files.map { |file| file[:header]["attachment_type"] }).to eq(%w[event.minidump event.attachment])
  end

  it "rejects duplicated file fields and excessive attachment counts" do
    expect { parse([ [ "upload_file_minidump", "a.dmp", "MDMP" ], [ "upload_file_minidump", "b.dmp", "MDMP" ] ]) }.to raise_error(Crashes::Rejected, "duplicate_file_field")
    expect { parse(Array.new(Crashes::MAX_FILES + 1) { |i| [ "file#{i}", "a.dmp", "MDMP" ] }) }.to raise_error(Crashes::Rejected, "too_many_attachments")
  end

  it "rejects missing dump fields, malformed metadata and invalid multipart types" do
    expect { parse([ [ "diagnostic", "note.txt", "text" ] ]) }.to raise_error(Crashes::Rejected, "missing_minidump")
    [ "{", { release: 1 }.to_json, { release: "x" * 1025 }.to_json, { release: "a\0b" }.to_json ].each do |metadata|
      expect { parse([ [ "sentry", nil, metadata ], [ "upload_file_minidump", "a.dmp", "MDMP" ] ]) }.to raise_error(Crashes::Rejected)
    end
    expect { described_class.call(body: StringIO.new("text"), content_type: "text/plain") }.to raise_error(Crashes::Rejected, "invalid_multipart")
  end

  it "rejects the wire budget before attempting multipart parsing" do
    expect { described_class.call(body: StringIO.new("x" * (Crashes::MAX_WIRE + 1)), content_type: "text/plain") }.to raise_error(Crashes::Rejected, "request_too_large")
  end
end
