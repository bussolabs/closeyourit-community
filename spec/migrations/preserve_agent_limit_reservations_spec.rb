# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260713183000_preserve_agent_limit_reservations")

RSpec.describe PreserveAgentLimitReservations, :silence_output do
  subject(:migration) { described_class.new }

  let(:connection) { instance_double(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) }

  before do
    allow(migration).to receive(:connection).and_return(connection)
    allow(connection).to receive(:change_column_null)
    allow(connection).to receive(:remove_foreign_key)
    allow(connection).to receive(:add_foreign_key)
  end

  it "ripara uno schema legacy in cui la create migration era già passata senza agent_id" do
    allow(connection).to receive(:column_exists?)
      .with("agents_limit_reservations", :agent_id).and_return(false)
    allow(connection).to receive(:foreign_key_exists?)
      .with("agents_limit_reservations", column: :agent_id).and_return(false)
    allow(connection).to receive(:add_reference)

    migration.migrate(:up)

    expect(connection).to have_received(:add_reference).with(
      "agents_limit_reservations",
      :agent,
      type: :uuid,
      null: true,
      index: true
    ).ordered
    expect(connection).to have_received(:change_column_null)
      .with("agents_limit_reservations", :agent_id, true).ordered
    expect(connection).not_to have_received(:remove_foreign_key)
    expect(connection).to have_received(:add_foreign_key).with(
      "agents_limit_reservations",
      :agents_agents,
      column: :agent_id,
      on_delete: :nullify
    ).ordered
  end

  it "converte la foreign key cascade di una installazione fresca in nullify" do
    allow(connection).to receive(:column_exists?)
      .with("agents_limit_reservations", :agent_id).and_return(true)
    allow(connection).to receive(:foreign_key_exists?)
      .with("agents_limit_reservations", column: :agent_id).and_return(true)

    migration.migrate(:up)

    expect(connection).to have_received(:change_column_null)
      .with("agents_limit_reservations", :agent_id, true).ordered
    expect(connection).to have_received(:remove_foreign_key)
      .with("agents_limit_reservations", hash_including(column: :agent_id)).ordered
    expect(connection).to have_received(:add_foreign_key).with(
      "agents_limit_reservations",
      :agents_agents,
      column: :agent_id,
      on_delete: :nullify
    ).ordered
  end
end
