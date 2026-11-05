# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::EventDefinition, type: :model do
  it "has a valid factory" do
    expect(build(:analytics_event_definition)).to be_valid
  end

  it "requires a name unique per project, and never the page visit itself" do
    existing = create(:analytics_event_definition, name: "Signup")
    expect(build(:analytics_event_definition, project: existing.project, name: "Signup")).not_to be_valid
    expect(build(:analytics_event_definition, name: "Signup")).to be_valid
    expect(build(:analytics_event_definition, name: " ")).not_to be_valid
    expect(build(:analytics_event_definition, name: "pageview")).not_to be_valid
  end

  it "accepts property names as a list or as comma separated text, cleaned and without repeats" do
    expect(build(:analytics_event_definition, property_names: " plan, seats ,plan,, ").property_names).to eq(%w[plan seats])
    expect(build(:analytics_event_definition, property_names: [ "plan", "", "seats" ]).property_names).to eq(%w[plan seats])
  end

  it "accepts at most ten property names of at most forty characters" do
    expect(build(:analytics_event_definition, property_names: (1..11).map { "p#{_1}" })).not_to be_valid
    expect(build(:analytics_event_definition, property_names: [ "k" * 41 ])).not_to be_valid
  end
end
