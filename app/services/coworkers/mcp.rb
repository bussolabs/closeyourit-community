require "net/http"
require "timeout"

module Coworkers
  # A small MCP client over Streamable HTTP (CYRA-1014): initialize, list the tools, call one.
  # Rails is the only side that holds the token; the address is pinned to the IP checked by NetworkGuard.
  # Each answer is capped in bytes and the whole conversation shares one deadline (CYRA-1126).
  module Mcp
    class Error < StandardError; end
    PROTOCOL = "2025-06-18".freeze
    TIMEOUT = 15 # seconds for initialize, the notification and the real call together
    MAX_BYTES = 1.megabyte
    # A broken or hostile app can fail in any of these ways; each must end as a readable error.
    NETWORK_ERRORS = [ SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError, Zlib::Error,
                       Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError ].freeze

    def self.list_tools(connection)
      tools = converse do |deadline|
        session = start(connection, deadline)
        request(connection, "tools/list", {}, session, deadline)&.dig("result", "tools")
      end
      Array(tools).first(Connection::MAX_TOOLS).map do |tool|
        { "name" => tool["name"].to_s, "description" => tool["description"].to_s.first(500),
          "input_schema" => tool["inputSchema"].is_a?(Hash) ? tool["inputSchema"] : { "type" => "object" },
          "read_only" => tool.dig("annotations", "readOnlyHint") == true }
      end
    end

    def self.call_tool(connection, name, arguments)
      result = converse do |deadline|
        session = start(connection, deadline)
        request(connection, "tools/call", { name: name, arguments: arguments }, session, deadline)&.dig("result")
      end
      raise Error, "empty_result" if result.nil?

      text = Array(result["content"]).filter_map { |part| part["text"] if part["type"] == "text" }.join("\n").first(8000)
      { error: result["isError"] == true, text: text }
    end

    # Timeout, oversized answer and unreachable server each become a distinct readable error.
    # The outer timeout also interrupts what BoundedHttp does not cover, such as a DNS lookup that hangs.
    def self.converse
      Timeout.timeout(TIMEOUT) { yield clock + TIMEOUT }
    rescue Timeout::Error
      raise Error, "timeout"
    rescue BoundedHttp::ResponseTooLarge
      raise Error, "too_large"
    rescue *NETWORK_ERRORS
      raise Error, "unreachable"
    end

    def self.start(connection, deadline)
      response = post(connection, deadline, { jsonrpc: "2.0", id: 1, method: "initialize",
                                              params: { protocolVersion: PROTOCOL, capabilities: {}, clientInfo: { name: "closeyourit-puckies", version: "1" } } })
      session = response["Mcp-Session-Id"]
      post(connection, deadline, { jsonrpc: "2.0", method: "notifications/initialized" }, session)
      session
    end

    def self.request(connection, method, params, session, deadline)
      parse(post(connection, deadline, { jsonrpc: "2.0", id: SecureRandom.random_number(1_000_000), method: method, params: params }, session))
    end

    def self.post(connection, deadline, body, session = nil)
      uri = URI.parse(connection.url)
      address = NetworkGuard.resolved_public_address(uri.host)
      raise Error, "unsafe_address" if address.nil? || uri.scheme != "https"

      remaining = deadline - clock
      raise Error, "timeout" unless remaining.positive?

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.ipaddr = address
      http.open_timeout = remaining
      http.read_timeout = remaining
      request = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream",
                                                      "MCP-Protocol-Version" => PROTOCOL)
      request["Authorization"] = "Bearer #{connection.token}" if connection.token.present?
      request["Mcp-Session-Id"] = session if session
      request.body = body.to_json
      BoundedHttp.request(http, request, max_bytes: MAX_BYTES, timeout: remaining)
                 .tap { |response| raise Error, "http_#{response.code}" unless response.code.to_i.between?(200, 299) }
    end

    # JSON, or the last JSON message of an event stream.
    def self.parse(response)
      body = response.body.to_s
      return nil if body.blank?
      return JSON.parse(body) unless response["Content-Type"].to_s.include?("text/event-stream")

      data = body.lines.filter_map { |line| line.delete_prefix("data:").strip if line.start_with?("data:") }.last
      data && JSON.parse(data)
    rescue JSON::ParserError
      raise Error, "invalid_response"
    end

    def self.clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    private_class_method :converse, :start, :request, :post, :parse, :clock
  end
end
