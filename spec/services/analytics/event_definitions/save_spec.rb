# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::EventDefinitions::Save do
  let(:project) { create(:project) }

  it "creates a declared event on the project" do
    result = described_class.call(project:, attributes: { name: "Signup", property_names: "plan, seats" })

    expect(result).to be_ok
    expect(result.value).to be_persisted
    expect(project.analytics_event_definitions.reload.map { [ _1.name, _1.property_names ] }).to eq([ [ "Signup", %w[plan seats] ] ])
  end

  it "updates an existing declared event" do
    definition = create(:analytics_event_definition, project:, name: "Signup")

    result = described_class.call(project:, definition:, attributes: { property_names: [ "plan", "coupon" ] })

    expect(result).to be_ok
    expect(definition.reload.property_names).to eq(%w[plan coupon])
  end

  it "rejects a duplicate name with a domain error and saves nothing" do
    create(:analytics_event_definition, project:, name: "Signup")

    result = described_class.call(project:, attributes: { name: "Signup" })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-EVENTDEF-001")
    expect(result.error.details).to have_key(:name)
    expect(project.analytics_event_definitions.count).to eq(1)
  end
end
