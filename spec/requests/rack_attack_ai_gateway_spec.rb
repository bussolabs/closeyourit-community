# frozen_string_literal: true

require "rails_helper"

# CYRA-1046: the AI gateway (/v1/, api.closeyour.it) had no per-minute limit; api/ip covers /api/ only.
# rack-attack is disabled in tests (spec/support/rack_attack.rb), so the throttle block is called directly.
RSpec.describe "Rack::Attack — AI gateway", type: :request do
  let(:throttle) { Rack::Attack.throttles.fetch("ai_gateway/key") }

  def attack_request(path, method: "POST", token: "cyi_ai_secret")
    env = { method: method, "REMOTE_ADDR" => "203.0.113.7" }
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    Rack::Attack::Request.new(Rack::MockRequest.env_for(path, env))
  end

  it "limits to 60 requests a minute" do
    expect(throttle.limit).to eq(60)
    expect(throttle.period).to eq(60)
  end

  %w[/v1/chat/completions /v1/embeddings /v1/rerank /v1/audio/transcriptions].each do |path|
    it "keys POST #{path} by the presented key, never by the key itself" do
      key = throttle.block.call(attack_request(path))

      expect(key).to be_present
      expect(key).not_to include("cyi_ai_secret")
    end
  end

  it "gives two keys two separate counters" do
    expect(throttle.block.call(attack_request("/v1/embeddings", token: "cyi_ai_one")))
      .not_to eq(throttle.block.call(attack_request("/v1/embeddings", token: "cyi_ai_two")))
  end

  it "falls back to the IP when no key is presented" do
    expect(throttle.block.call(attack_request("/v1/embeddings", token: nil))).to eq("203.0.113.7")
  end

  it "leaves /api/v1/ and GET requests alone" do
    expect(throttle.block.call(attack_request("/api/v1/projects/1/events"))).to be_nil
    expect(throttle.block.call(attack_request("/v1/embeddings", method: "GET"))).to be_nil
  end
end
