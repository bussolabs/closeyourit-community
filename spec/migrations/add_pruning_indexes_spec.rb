# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261124100000_add_pruning_indexes")

RSpec.describe AddPruningIndexes do
  self.use_transactional_tests = false

  it "recovers invalid indexes and supports up, down and reapplication without transactions" do
    pool = ActiveRecord::Base.connection_pool
    connection = pool.checkout
    original_path = connection.schema_search_path
    schema = "pruning_#{SecureRandom.hex(8)}"
    connection.execute("CREATE SCHEMA #{schema}")
    connection.schema_search_path = schema
    connection.execute("CREATE TABLE alerting_notifications (created_at timestamp NOT NULL)")
    connection.execute("CREATE TABLE analytics_web_vitals (project_id bigint, created_at timestamp NOT NULL)")
    connection.execute("INSERT INTO alerting_notifications VALUES ('2026-01-01'), ('2026-01-01')")
    connection.execute("INSERT INTO analytics_web_vitals VALUES (1, '2026-01-01'), (1, '2026-01-01')")

    %w[alerting_notifications analytics_web_vitals].each do |table|
      expect do
        connection.execute("CREATE UNIQUE INDEX CONCURRENTLY idx_#{table}_retention ON #{table} (created_at)")
      end.to raise_error(ActiveRecord::RecordNotUnique)
      expect(connection.indexes(table).find { |index| index.name == "idx_#{table}_retention" }.valid?).to be(false)
    end

    migration = described_class.new
    allow(migration).to receive(:connection).and_return(connection)
    migration.up
    expect_valid_indexes(connection)
    migration.down
    expect(connection.indexes(:alerting_notifications)).to be_empty
    expect(connection.indexes(:analytics_web_vitals)).to be_empty
    migration.up
    expect_valid_indexes(connection)
  ensure
    if connection
      connection.schema_search_path = original_path
      connection.execute("DROP SCHEMA IF EXISTS #{schema} CASCADE") if schema
      pool.checkin(connection)
    end
  end

  def expect_valid_indexes(connection)
    notification_index = connection.indexes(:alerting_notifications).sole
    vital_index = connection.indexes(:analytics_web_vitals).sole
    expect(notification_index.columns).to eq([ "created_at" ])
    expect(vital_index.columns).to eq([ "project_id", "created_at" ])
    expect(notification_index.valid?).to be(true)
    expect(vital_index.valid?).to be(true)
  end
end
