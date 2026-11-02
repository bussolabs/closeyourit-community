require "rails_helper"

RSpec.describe Coworkers::Mcp do
  let(:url) { "https://mcp.example.com/mcp" }
  let(:connection) { Coworkers::Connection.new(provider: "mcp", name: "Notion", url: url, token: "secret-token") }
  let(:initialize_stub) do
    stub_request(:post, url).with { |req| JSON.parse(req.body)["method"] == "initialize" }
                            .to_return(status: 200, headers: { "Mcp-Session-Id" => "sess-1" }, body: "")
  end
  let(:initialized_stub) do
    stub_request(:post, url).with { |req| JSON.parse(req.body)["method"] == "notifications/initialized" }.to_return(status: 202)
  end

  before do
    allow(NetworkGuard).to receive(:resolved_public_address).and_return("93.184.215.14")
    initialize_stub
    initialized_stub
  end

  def stub_method(method, body:, content_type: "application/json", status: 200)
    stub_request(:post, url).with { |req| JSON.parse(req.body)["method"] == method }
                            .to_return(status: status, headers: { "Content-Type" => content_type }, body: body)
  end

  describe ".list_tools" do
    it "normalizes the tools and sends the token and the session id" do
      stub_method("tools/list", body: { result: { tools: [
        { name: "search", description: "Find", inputSchema: { type: "object", properties: {} }, annotations: { readOnlyHint: true } },
        { name: "write", inputSchema: "broken" }
      ] } }.to_json)

      expect(described_class.list_tools(connection)).to eq([
        { "name" => "search", "description" => "Find", "input_schema" => { "type" => "object", "properties" => {} }, "read_only" => true },
        { "name" => "write", "description" => "", "input_schema" => { "type" => "object" }, "read_only" => false }
      ])
      list_request = a_request(:post, url).with(headers: { "Authorization" => "Bearer secret-token", "Mcp-Session-Id" => "sess-1" }) do |req|
        JSON.parse(req.body)["method"] == "tools/list"
      end
      expect(list_request).to have_been_made.once
    end

    it "returns no tools for an empty answer and omits the token when there is none" do
      connection.token = nil
      stub_method("tools/list", body: "")

      expect(described_class.list_tools(connection)).to eq([])
      expect(a_request(:post, url).with { |req| req.headers.key?("Authorization") }).not_to have_been_made
    end

    it "sends no session header when the server opens none" do
      stub_request(:post, url).with { |req| JSON.parse(req.body)["method"] == "initialize" }.to_return(status: 200, body: "")
      stub_method("tools/list", body: { result: { tools: [] } }.to_json)

      expect(described_class.list_tools(connection)).to eq([])
      expect(a_request(:post, url).with { |req| req.headers.key?("Mcp-Session-Id") }).not_to have_been_made
    end

    it "reads the last message of an event stream" do
      stream = "event: message\ndata: {\"result\":{\"tools\":[]}}\n\ndata: {\"result\":{\"tools\":[{\"name\":\"last\"}]}}\n"
      stub_method("tools/list", body: stream, content_type: "text/event-stream")

      expect(described_class.list_tools(connection).map { |tool| tool["name"] }).to eq([ "last" ])
    end

    it "returns no tools for an event stream without data lines" do
      stub_method("tools/list", body: ": keep-alive\n", content_type: "text/event-stream")

      expect(described_class.list_tools(connection)).to eq([])
    end

    it "raises on a body that is not JSON" do
      stub_method("tools/list", body: "<html>")

      expect { described_class.list_tools(connection) }.to raise_error(described_class::Error, "invalid_response")
    end

    it "raises on a status outside 2xx" do
      stub_method("tools/list", body: "", status: 401)

      expect { described_class.list_tools(connection) }.to raise_error(described_class::Error, "http_401")
    end

    it "refuses an address that does not resolve to a public IP" do
      allow(NetworkGuard).to receive(:resolved_public_address).and_return(nil)

      expect { described_class.list_tools(connection) }.to raise_error(described_class::Error, "unsafe_address")
      expect(initialize_stub).not_to have_been_requested
    end

    it "refuses a plain http address" do
      connection.url = "http://mcp.example.com/mcp"

      expect { described_class.list_tools(connection) }.to raise_error(described_class::Error, "unsafe_address")
    end
  end

  describe "network failures (CYRA-1126)" do
    it "stops reading an answer over the byte cap" do
      stub_method("tools/list", body: "x" * (described_class::MAX_BYTES + 1))

      expect { described_class.list_tools(connection) }.to raise_error(described_class::Error, "too_large")
    end

    it "turns a read that times out into a readable error" do
      stub_request(:post, url).with { |req| JSON.parse(req.body)["method"] == "tools/list" }.to_timeout

      expect { described_class.list_tools(connection) }.to raise_error(described_class::Error, "timeout")
    end

    it "shares one deadline across the whole conversation" do
      allow(described_class).to receive(:clock).and_return(0.0, 1.0, described_class::TIMEOUT + 1.0)
      list_stub = stub_method("tools/list", body: { result: { tools: [] } }.to_json)

      expect { described_class.list_tools(connection) }.to raise_error(described_class::Error, "timeout")
      expect(initialize_stub).to have_been_requested
      expect(initialized_stub).not_to have_been_requested
      expect(list_stub).not_to have_been_requested
    end

    it "bounds each call with what is left of the deadline" do
      allow(described_class).to receive(:clock).and_return(0.0, 0.0, 5.0, 12.0)
      allow(BoundedHttp).to receive(:request).and_call_original
      stub_method("tools/list", body: { result: { tools: [] } }.to_json)

      described_class.list_tools(connection)

      expect(BoundedHttp).to have_received(:request).with(anything, anything, max_bytes: 1.megabyte, timeout: 15.0)
      expect(BoundedHttp).to have_received(:request).with(anything, anything, max_bytes: 1.megabyte, timeout: 10.0)
      expect(BoundedHttp).to have_received(:request).with(anything, anything, max_bytes: 1.megabyte, timeout: 3.0)
    end

    it "interrupts a name lookup that hangs past the deadline" do
      stub_const("#{described_class}::TIMEOUT", 0.2)
      lookups = 0
      allow(NetworkGuard).to receive(:resolved_public_address) do
        lookups += 1
        sleep 5 if lookups == 2
        "93.184.215.14"
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect { described_class.list_tools(connection) }.to raise_error(described_class::Error, "timeout")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      expect(initialize_stub).to have_been_requested
      expect(initialized_stub).not_to have_been_requested
    end

    it "turns a server that cannot be reached into a readable error" do
      stub_request(:post, url).with { |req| JSON.parse(req.body)["method"] == "initialize" }.to_raise(Errno::ECONNREFUSED)

      expect { described_class.call_tool(connection, "search", {}) }.to raise_error(described_class::Error, "unreachable")
    end

    it "turns a broken TLS handshake into a readable error" do
      stub_request(:post, url).with { |req| JSON.parse(req.body)["method"] == "initialize" }.to_raise(OpenSSL::SSL::SSLError)

      expect { described_class.list_tools(connection) }.to raise_error(described_class::Error, "unreachable")
    end
  end

  describe ".call_tool" do
    it "joins the text parts and reports the server's error flag" do
      stub_method("tools/call", body: { result: { isError: true, content: [
        { type: "text", text: "first" }, { type: "image", data: "x" }, { type: "text", text: "second" }
      ] } }.to_json)

      expect(described_class.call_tool(connection, "search", { "q" => "release" })).to eq(error: true, text: "first\nsecond")
      expect(a_request(:post, url).with { |req| JSON.parse(req.body)["params"] == { "name" => "search", "arguments" => { "q" => "release" } } })
        .to have_been_made.once
    end

    it "raises when the answer carries no result" do
      stub_method("tools/call", body: { error: { code: -32_601 } }.to_json)

      expect { described_class.call_tool(connection, "search", {}) }.to raise_error(described_class::Error, "empty_result")
    end

    it "raises when the answer is empty" do
      stub_method("tools/call", body: "")

      expect { described_class.call_tool(connection, "search", {}) }.to raise_error(described_class::Error, "empty_result")
    end
  end
end
