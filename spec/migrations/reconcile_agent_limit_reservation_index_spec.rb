# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260714003000_reconcile_agent_limit_reservation_index")

RSpec.describe ReconcileAgentLimitReservationIndex, :silence_output do
  subject(:migration) { described_class.new }

  let(:connection) { instance_double(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) }

  before do
    allow(migration).to receive(:connection).and_return(connection)
    allow(connection).to receive(:add_index)
    allow(connection).to receive(:remove_index)
  end

  it "aggiunge l'indice assente negli schemi creati dalla prima versione della migration" do
    allow(connection).to receive(:index_exists?)
      .with("agents_limit_reservations", name: described_class::INDEX_NAME).and_return(false)

    migration.migrate(:up)

    expect(connection).to have_received(:add_index).with(
      "agents_limit_reservations",
      %i[organization_id expires_at],
      where: "outcome = 'granted'",
      name: described_class::INDEX_NAME
    )
  end

  it "non ricrea l'indice presente nelle installazioni fresche" do
    allow(connection).to receive(:index_exists?)
      .with("agents_limit_reservations", name: described_class::INDEX_NAME).and_return(true)

    migration.migrate(:up)

    expect(connection).not_to have_received(:add_index)
  end

  it "preserva al rollback l'indice che appartiene alla create migration" do
    migration.migrate(:down)

    expect(connection).not_to have_received(:remove_index)
  end
end
