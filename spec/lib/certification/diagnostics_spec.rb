# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../../../script/certification/diagnostics"

RSpec.describe Certification::Diagnostics do
  around do |example|
    Dir.mktmpdir("certification-diagnostics") do |directory|
      @path = File.join(directory, "diagnostics.jsonl")
      example.run
    end
  end

  let(:project_id) { "12345678-1234-1234-1234-123456789abc" }
  let(:sink) { described_class.new(@path) }

  it "retains rejection counts scoped to the project without the message" do
    2.times { sink.write("Metrics::IngestJob 3 rejected samples: R422-METRIC-002 project_id=#{project_id}\n") }
    sink.write("Metrics::IngestJob 1 rejected samples: R422-METRIC-003 project_id=aaaaaaaa-1234-1234-1234-123456789abc\n")
    expect(described_class.read(@path, project_id:)).to eq([ { code: "R422-METRIC-002", count: 6 } ])
    expect(File.read(@path)).not_to include("rejected samples")
  end

  it "discards ordinary logs and credentials" do
    sink.write("Authorization: Bearer private-test-value\n")
    sink.write("An exception occurred with password=private-test-value\n")
    expect(File).not_to exist(@path)
  end

  it "does not accept an embedded rejection message" do
    sink.write("Untrusted message: Metrics::IngestJob 3 rejected samples: R422-METRIC-002 project_id=#{project_id}\n")
    expect(File).not_to exist(@path)
  end

  it "bounds the artifact size" do
    2000.times { sink.write("Metrics::IngestJob 1 rejected samples: R422-METRIC-002 project_id=#{project_id}\n") }
    expect(File.size(@path)).to be <= described_class::MAX_BYTES
    expect(described_class.read(@path, project_id:).first[:count]).to be < 2000
  end

  it "rejects malformed artifacts without exposing their content" do
    File.write(@path, "private-test-value")
    expect { described_class.read(@path, project_id:) }.to raise_error("Invalid certification diagnostic artifact")
  end

  it "rejects forged diagnostic codes" do
    File.write(@path, JSON.generate(code: "private-test-value", count: 1, project_id:))
    expect { described_class.read(@path, project_id:) }.to raise_error("Invalid certification diagnostic artifact")
  end
end
