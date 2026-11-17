# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261117090000_drop_ticketing_scenarios_and_conditions")

# CYRA-1321 — the old tables go only after their last rows are in the one list: scenarios first, then
# conditions, numbered after the codes a ticket already has.
RSpec.describe DropTicketingScenariosAndConditions do
  let(:connection) { ActiveRecord::Base.connection }
  let(:ticket) { create(:ticket, description: "Plain body, no default scenario.") }

  def migrate(direction) = ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }

  def insert(table, attributes)
    columns = attributes.keys.join(", ")
    values = attributes.values.map { connection.quote(it) }.join(", ")
    connection.execute(
      "INSERT INTO #{table} (id, ticket_id, created_at, updated_at, #{columns}) " \
      "VALUES (gen_random_uuid(), #{connection.quote(ticket.id)}, now(), now(), #{values})"
    )
  end

  # The schema under test has no old tables any more: rolling back puts them back, empty.
  before { migrate(:down) }

  it "copies the rows left in the old tables into the one list, then drops the tables" do
    create(:ticketing_condition, ticket:, text: "Already here")
    insert("ticketing_conditions", position: 5, text: "Written by an old container")
    insert("ticketing_scenarios", position: 0, title: "Link present", step_given: "a client", step_expected: "a link")

    migrate(:up)

    items = ticket.reload.acceptance_items
    expect(items.map { [ it.code, it.format, it.title || it.text ] })
      .to contain_exactly([ "AC-1", "text", "Already here" ], [ "AC-2", "scenario", "Link present" ],
                          [ "AC-3", "text", "Written by an old container" ])
    expect(ticket.last_acceptance_item_number).to eq(3)
    expect(connection.table_exists?(:ticketing_scenarios)).to be(false)
    expect(connection.table_exists?(:ticketing_conditions)).to be(false)
  end
end
