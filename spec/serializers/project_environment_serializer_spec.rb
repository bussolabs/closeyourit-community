# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectEnvironmentSerializer do
  it "espone l'override (nil = eredita) e il valore risolto di ogni capability" do
    project = create(:project)
    env = create(:environment, organization: project.organization, uptime_enabled: false, servers_enabled: true, secrets_enabled: true)
    # uptime: override esplicito ON; servers/secrets: nil = eredita il default dell'ambiente.
    link = create(:project_environment, project:, environment: env, uptime_enabled: true)
    json = JSON.parse(described_class.new(link).serialize)

    expect(json["environment_id"]).to eq(env.id)
    expect(json["code"]).to eq(env.code)
    expect(json["uptime_override"]).to be(true)
    expect(json["uptime_enabled"]).to be(true)   # override batte il default OFF
    expect(json["servers_override"]).to be_nil
    expect(json["servers_enabled"]).to be(true)  # eredita il default ON
    expect(json["secrets_override"]).to be_nil
    expect(json["secrets_enabled"]).to be(true)  # eredita il default ON
  end
end
