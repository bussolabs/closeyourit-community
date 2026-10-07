require "net/http"

module Coworkers
  # A small MCP client over Streamable HTTP (CYRA-1014): initialize, list the tools, call one.
  # Rails is the only side that holds the token; the address is pinned to the IP checked by NetworkGuard.
  module Mcp
    class Error < StandardError; end
    PROTOCOL = "2025-06-18".freeze
    TIMEOUT = 15

    def self.list_tools(connection)
      session = start(connection)
      tools = request(connection, "tools/list", {}, session)&.dig("result", "tools")
      Array(tools).first(Connection::MAX_TOOLS).map do |tool|
        { "name" => tool["name"].to_s, "description" => tool["description"].to_s.first(500),
          "input_schema" => tool["inputSchema"].is_a?(Hash) ? tool["inputSchema"] : { "type" => "object" },
          "read_only" => tool.dig("annotations", "readOnlyHint") == true }
      end
    end

    def self.call_tool(connection, name, arguments)
      session = start(connection)
      result = request(connection, "tools/call", { name: name, arguments: arguments }, session)&.dig("result")
      raise Error, "empty_result" if result.nil?

      text = Array(result["content"]).filter_map { |part| part["text"] if part["type"] == "text" }.join("\n").first(8000)
      { error: result["isError"] == true, text: text }
    end

    def self.start(connection)
      response = post(connection, { jsonrpc: "2.0", id: 1, method: "initialize",
                                    params: { protocolVersion: PROTOCOL, capabilities: {}, clientInfo: { name: "closeyourit-puckies", version: "1" } } })
      session = response["Mcp-Session-Id"]
      post(connection, { jsonrpc: "2.0", method: "notifications/initialized" }, session)
      session
    end

    def self.request(connection, method, params, session)
      parse(post(connection, { jsonrpc: "2.0", id: SecureRandom.random_number(1_000_000), method: method, params: params }, session))
    end

    def self.post(connection, body, session = nil)
      uri = URI.parse(connection.url)
      address = NetworkGuard.resolved_public_address(uri.host)
      raise Error, "unsafe_address" if address.nil? || uri.scheme != "https"

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.ipaddr = address
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT
      request = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream",
                                                      "MCP-Protocol-Version" => PROTOCOL)
      request["Authorization"] = "Bearer #{connection.token}" if connection.token.present?
      request["Mcp-Session-Id"] = session if session
      request.body = body.to_json
      http.request(request).tap { |response| raise Error, "http_#{response.code}" unless response.code.to_i.between?(200, 299) }
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
    private_class_method :start, :request, :post, :parse
  end
end
