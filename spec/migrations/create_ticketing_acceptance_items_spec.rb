# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261116230000_create_ticketing_acceptance_items")

# CYRA-1317 — the copy from the old tables: scenarios first, then conditions, codes from AC-1, run twice safely.
RSpec.describe CreateTicketingAcceptanceItems do
  let(:ticket) { create(:ticket, description: "Plain body, no default scenario.") }

  def insert(table, attributes)
    columns = attributes.keys.join(", ")
    values = attributes.values.map { ActiveRecord::Base.connection.quote(it) }.join(", ")
    ActiveRecord::Base.connection.execute(
      "INSERT INTO #{table} (id, ticket_id, created_at, updated_at, #{columns}) " \
      "VALUES (gen_random_uuid(), #{ActiveRecord::Base.connection.quote(ticket.id)}, now(), now(), #{values})"
    )
  end

  def backfill = ActiveRecord::Migration.suppress_messages { described_class.new.backfill }

  it "copies scenarios then conditions into one list, and copies nothing twice" do
    insert("ticketing_conditions", position: 0, text: "Templates inspected")
    insert("ticketing_scenarios", position: 0, title: "Link present", step_given: "a client", step_expected: "a link")

    backfill
    backfill

    items = ticket.reload.acceptance_items
    expect(items.map { [ it.code, it.format, it.title || it.text ] })
      .to eq([ [ "AC-1", "scenario", "Link present" ], [ "AC-2", "text", "Templates inspected" ] ])
    expect(ticket.last_acceptance_item_number).to eq(2)
  end

  it "numbers late rows after the codes already given" do
    create(:ticketing_condition, ticket:, text: "Already here")
    insert("ticketing_conditions", position: 5, text: "Written by an old container")

    backfill

    expect(ticket.reload.acceptance_items.map(&:code)).to eq(%w[AC-1 AC-2])
    expect(ticket.last_acceptance_item_number).to eq(2)
  end
end
