# frozen_string_literal: true

require "rails_helper"

RSpec.describe EnvironmentSerializer do
  it "espone i default di capability dell'ambiente" do
    env = create(:environment, servers_enabled: true, uptime_enabled: false, secrets_enabled: true)
    json = JSON.parse(described_class.new(env).serialize)

    expect([ json["servers_enabled"], json["uptime_enabled"], json["secrets_enabled"] ]).to eq([ true, false, true ])
  end
end
