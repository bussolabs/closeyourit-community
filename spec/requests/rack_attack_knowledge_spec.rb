# frozen_string_literal: true

require "rails_helper"

# CYRA-764 — ogni salvataggio di pagina di conoscenza spende una chiamata SINCRONA al revisore
# (10-25 s di modello): senza un tetto un modulo in ciclo o uno script tengono occupati i thread e
# il server AI di casa. Web per IP (c'è la sessione), CLI per token (come l'assistente).
RSpec.describe "Rack::Attack — salvataggi knowledge", type: :request do
  let(:web_throttle) { Rack::Attack.throttles.fetch("knowledge_write/ip") }
  let(:cli_throttle) { Rack::Attack.throttles.fetch("knowledge_cli_write/token") }
  let(:token) { "cyi_u_unsegretoqualsiasi" }

  def attack_request(path, method: "POST", bearer: nil, ip: "203.0.113.7")
    env = Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => ip)
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" if bearer
    Rack::Attack::Request.new(env)
  end

  it "il web conta per IP le scritture di pagina, non le letture" do
    expect(web_throttle.block.call(attack_request("/member/knowledge/pages"))).to eq("203.0.113.7")
    expect(web_throttle.block.call(attack_request("/member/knowledge/pages/abc", method: "PATCH"))).to eq("203.0.113.7")
    expect(web_throttle.block.call(attack_request("/member/knowledge/pages", method: "GET"))).to be_nil
    expect(web_throttle.block.call(attack_request("/member/knowledge/pages/abc/attachments"))).to be_nil
    expect(web_throttle.limit).to eq(20)
  end

  it "la CLI conta per token pagine e pubblicazioni, mai il segreto in chiaro" do
    key = cli_throttle.block.call(attack_request("/cli/v1/knowledge/pages", bearer: token))
    expect(key).to be_present.and match(/\A[0-9a-f]+\z/)
    expect(key).not_to include(token)
    expect(cli_throttle.block.call(attack_request("/cli/v1/knowledge/pages/abc", method: "PATCH", bearer: token))).to eq(key)
    expect(cli_throttle.block.call(attack_request("/cli/v1/projects/p1/knowledge/publications/kb:x", method: "PUT", bearer: token))).to eq(key)
    expect(cli_throttle.block.call(attack_request("/cli/v1/knowledge/pages", method: "GET", bearer: token))).to be_nil
    expect(cli_throttle.block.call(attack_request("/cli/v1/knowledge/pages"))).to be_nil
  end
end
