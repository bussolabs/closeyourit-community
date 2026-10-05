# frozen_string_literal: true

require "rails_helper"

RSpec.describe Crashes::Decode do
  it "scrubs text without trusting its filename or declared media type" do
    decoded = described_class.call(header: { "filename" => "../../user@example.com.txt", "content_type" => "text/html" }, bytes: "password=private\nhello")
    expect(decoded.fetch(:bytes)).to eq("password=[FILTERED]\nhello")
    expect(decoded.fetch(:filename)).not_to include("..", "user@example.com")
    expect(decoded.fetch(:kind)).to eq("text")
  end

  it "rejects opaque bytes and oversized attachments before processing" do
    expect { described_class.call(header: {}, bytes: "\xff\x00".b) }.to raise_error(Crashes::Rejected, "unsupported_binary")
    expect { described_class.call(header: {}, bytes: "x" * (Crashes::MAX_FILE + 1)) }.to raise_error(Crashes::Rejected, "attachment_too_large")
  end

  it "accepts empty text while rejecting embedded NUL bytes" do
    expect(described_class.call(header: {}, bytes: "").fetch(:bytes)).to eq("")
    expect { described_class.call(header: {}, bytes: "a\x00b") }.to raise_error(Crashes::Rejected, "unsupported_binary")
  end

  it "rejects deeply nested JSON instead of falling back to weaker text scrubbing" do
    bytes = ('{"data":' * 33) + '{"password":123}' + ('}' * 33)
    expect { described_class.call(header: {}, bytes: bytes) }.to raise_error(Crashes::Rejected, "attachment_nesting_too_deep")
  end
end
