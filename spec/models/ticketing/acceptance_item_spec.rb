# frozen_string_literal: true

require "rails_helper"

# CYRA-1317 — one list of acceptance items per ticket; scenarios and conditions are its two formats.
RSpec.describe Ticketing::AcceptanceItem do
  let(:ticket) { create(:ticket, description: "Plain body, no default scenario.") }

  it "keeps scenarios and conditions in one ordered list with codes AC-1, AC-2" do
    scenario = create(:ticketing_scenario, ticket:, position: 0)
    condition = create(:ticketing_condition, ticket:, position: 1)

    items = ticket.reload.acceptance_items
    expect(items.map(&:class)).to eq([ Ticketing::Scenario, Ticketing::Condition ])
    expect(items.map(&:code)).to eq([ scenario.code, condition.code ])
    expect([ scenario.code, condition.code ]).to eq(%w[AC-1 AC-2])
    expect(ticket.scenarios).to eq([ scenario ])
    expect(ticket.conditions).to eq([ condition ])
  end

  it "never reuses a code after an item is deleted" do
    first = create(:ticketing_condition, ticket:)
    first.destroy!

    expect(create(:ticketing_condition, ticket:).code).to eq("AC-2")
  end

  it "bumps the revision when the content changes, not when only the order changes" do
    item = create(:ticketing_condition, ticket:, text: "The link is visible")

    item.update!(position: 3)
    expect(item.reload.revision).to eq(1)

    item.update!(text: "The link is visible and opens the client area")
    expect(item.reload.revision).to eq(2)
  end

  it "numbers the items of a ticket created with them in one save" do
    created = create(:ticket, scenarios_attributes: [ { step_given: "a client", step_expected: "a link" } ],
                              conditions_attributes: [ { text: "Templates inspected" } ])

    expect(created.reload.acceptance_items.map(&:code)).to contain_exactly("AC-1", "AC-2")
    expect(created.last_acceptance_item_number).to eq(2)
  end
end
