# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Processor endpoint boundaries" do
  [ [ "NATIVE_SYMBOL_PROCESSOR_URL", Artifacts::NativeSymbols::Processor, { bytes: "unvalidated", expected: {}, addresses: [] }, Artifacts::Unavailable ],
    [ "RETRACE_PROCESSOR_URL", Artifacts::ProguardMaps::Processor, { mapping: "unvalidated", stacktrace: [] }, Artifacts::Unavailable ],
    [ "CRASH_PROCESSOR_URL", Crashes::Processor, { bytes: "MDMP" + "\0" * 32 }, Crashes::Unavailable ] ].each do |key, processor, arguments, error|
    context processor.name do
      around do |example|
        previous = ENV[key]
        example.run
      ensure
        previous.nil? ? ENV.delete(key) : ENV[key] = previous
      end

      it "fails closed for absent endpoints and unsupported or credential-bearing URLs" do
        [ nil, "", "file:///tmp/processor", "http://test-user@localhost/process", "http://localhost/process?query=1", "http://localhost/process#fragment", "http://[invalid" ].each do |endpoint|
          endpoint.nil? ? ENV.delete(key) : ENV[key] = endpoint
          expect { processor.call(**arguments) }.to raise_error(error)
        end
      end

      it "normalizes a refused local connection without persisting an artifact" do
        socket = TCPServer.new("127.0.0.1", 0)
        port = socket.addr[1]
        socket.close
        ENV[key] = "http://127.0.0.1:#{port}/process"
        expect { processor.call(**arguments) }.to raise_error(error)
      ensure
        socket&.close unless socket&.closed?
      end
    end
  end

  it "rejects oversized native request metadata before opening a network connection" do
    processor = Artifacts::NativeSymbols::Processor.new(bytes: "x", expected: { name: "x" * Artifacts::NativeSymbols::Processor::MAX_REQUEST }, addresses: [])
    expect { processor.send(:request, URI("http://127.0.0.1:1/process")) }.to raise_error(Artifacts::Rejected, "request_too_large")
  end
end
