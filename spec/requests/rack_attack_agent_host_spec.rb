# frozen_string_literal: true

require "rails_helper"

# CYRA-1363 — the machines of a fleet leave from one address, and their requests fell in the per-address
# counter shared with the whole /api: on 2026-11-25 one machine was refused 847 work claims in a day.
#
# rack-attack is off in the whole suite (spec/support/rack_attack.rb): like the other throttle specs, the
# block of the rule is called directly.
RSpec.describe "Rack::Attack — agent host machines", type: :request do
  let(:token_throttle) { Rack::Attack.throttles.fetch("agent_host/token") }
  let(:ip_throttle) { Rack::Attack.throttles.fetch("agent_host/ip") }
  let(:api_throttle) { Rack::Attack.throttles.fetch("api/ip") }
  let(:token) { "cyi_ah_anysecretwhatever" }

  def attack_request(path, method: "POST", bearer: token, ip: "203.0.113.7")
    env = Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => ip)
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" if bearer
    Rack::Attack::Request.new(env)
  end

  it "counts a machine request on its own credential, reads included" do
    expect(token_throttle.block.call(attack_request("/api/v1/ticket_queue/next_claim"))).to be_present
    expect(token_throttle.block.call(attack_request("/api/v1/ticket_queue", method: "GET"))).to be_present
    expect(token_throttle.block.call(attack_request("/api/v1/agent_host/workspace_manifest", method: "GET"))).to be_present
  end

  it "keys on the truncated digest of the token, never on the secret" do
    key = token_throttle.block.call(attack_request("/api/v1/ticket_queue"))

    expect(key).not_to include(token)
    expect(Digest::SHA256.hexdigest(token)).to start_with(key)
    expect(key).not_to eq(Digest::SHA256.hexdigest(token))
  end

  it "gives two machines behind one address two separate counters" do
    first = token_throttle.block.call(attack_request("/api/v1/ticket_queue"))
    second = token_throttle.block.call(attack_request("/api/v1/ticket_queue", bearer: "cyi_ah_anothermachine"))

    expect(first).not_to eq(second)
  end

  it "takes the machine request out of the shared per-address counter" do
    expect(api_throttle.block.call(attack_request("/api/v1/ticket_queue/next_claim"))).to be_nil
  end

  it "keeps a ceiling per address, so rotating made-up tokens is not a way around the limit" do
    expect(ip_throttle.block.call(attack_request("/api/v1/ticket_queue"))).to eq("203.0.113.7")
    expect(ip_throttle.limit).to be > token_throttle.limit
  end

  it "leaves every other credential, and no credential, in the shared counter" do
    [ "cyi_u_ausertoken", nil ].each do |bearer|
      request = attack_request("/api/v1/ticket_queue", bearer:)

      expect(token_throttle.block.call(request)).to be_nil
      expect(ip_throttle.block.call(request)).to be_nil
      expect(api_throttle.block.call(request)).to eq("203.0.113.7")
    end
  end

  it "recognises the same prefix the server gives to machine tokens" do
    expect(Rack::Attack::AGENT_HOST_TOKEN_PREFIX).to eq(Agents::Constants::HOST_TOKEN_PREFIX)
  end

  it "does not apply outside /api" do
    expect(token_throttle.block.call(attack_request("/member/agents"))).to be_nil
  end
end
