# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::EventDefinitions::Delete do
  it "removes the declared event and leaves the stored events alone" do
    definition = create(:analytics_event_definition, name: "Signup")
    create(:pageview, project: definition.project, name: "Signup")

    expect(described_class.call(definition:)).to be_ok
    expect(Analytics::EventDefinition.exists?(definition.id)).to be(false)
    expect(definition.project.analytics_pageviews.count).to eq(1)
  end
end
