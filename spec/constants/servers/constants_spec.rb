# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::Constants do
  # The constants are read once at boot, so each case evaluates a fresh copy of the file.
  def constants_with(env)
    saved = ENV.to_h.slice(*env.keys)
    env.each { |name, value| value ? ENV[name] = value : ENV.delete(name) }
    Module.new.tap { |scope| scope.module_eval(Rails.root.join("app/constants/servers/constants.rb").read) }
              .const_get("Servers::Constants")
  ensure
    env.each_key { |name| ENV.delete(name) }
    saved.each { |name, value| ENV[name] = value }
  end

  it "pins every install snippet to the public release of the same agent version" do
    constants = constants_with("AGENT_IMAGE" => nil, "AGENT_RELEASE_URL" => nil, "AGENT_SOURCE_URL" => nil)

    version = "v#{constants::AGENT_VERSION}"
    expect(constants::AGENT_IMAGE).to eq("ghcr.io/bussolabs/closeyourit-agent:#{version}")
    expect(constants::AGENT_RELEASE_URL).to end_with("closeyourit-agent-community/releases/download/#{version}")
    expect(constants::AGENT_SOURCE_URL).to end_with("closeyourit-agent-community/#{version}")
  end

  it "lets a self-hosted install serve the no-Docker snippet from its own mirror" do
    constants = constants_with("AGENT_RELEASE_URL" => "https://mirror.example/agent/v1",
                               "AGENT_SOURCE_URL" => "https://mirror.example/agent-src/v1")

    expect(constants::AGENT_RELEASE_URL).to eq("https://mirror.example/agent/v1")
    expect(constants::AGENT_SOURCE_URL).to eq("https://mirror.example/agent-src/v1")
  end
end
