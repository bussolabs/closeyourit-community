# frozen_string_literal: true

require "rails_helper"

# CYAU-235 — built-in topics, plus the ones the organization and the project add. Adding only: a project
# never removes what the organization or the built-in list reserve.
RSpec.describe Agents::Supporters::ReservedTopics do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }

  def topics = described_class.new(organization: organization, project: project)

  it "reserves the built-in topics on every project" do
    expect(topics.match(text: "Should the price include VAT?")).to be_present
    expect(topics.match(text: "Rename the helper to formatLabel")).to be_empty
  end

  it "matches words whole, in any case" do
    create(:agent_automator_setting, organization: organization, supporter_reserved_topics: "stripe")
    expect(topics.match(text: "Retry the STRIPE webhook")).to be_present
    expect(topics.match(text: "stripes on the chart")).to be_empty
  end

  it "adds the organization topics and the project topics together" do
    create(:agent_automator_setting, organization: organization, supporter_reserved_topics: "stripe\n")
    project.update!(supporter_reserved_topics: "  paypal  \n\nmailchimp")

    sources = topics.entries.map { |entry| [ entry.value, entry.source ] }
    expect(sources).to include([ "stripe", :organization ], [ "paypal", :project ], [ "mailchimp", :project ])
    expect(topics.match(text: "Switch the PayPal sandbox")).to be_present
  end

  it "treats a line with a slash as a code path, matched by prefix" do
    project.update!(supporter_reserved_topics: "app/services/billing/")
    expect(topics.match(text: "Tidy up", paths: [ "app/services/billing/invoice.rb" ])).to be_present
    expect(topics.match(text: "Tidy up", paths: [ "app/services/reports/total.rb" ])).to be_empty
  end

  it "says which entry matched and where it comes from" do
    project.update!(supporter_reserved_topics: "paypal")
    entry = topics.match(text: "PayPal refund flow").find { |match| match.value == "paypal" }
    expect(entry.source).to eq(:project)
  end
end
