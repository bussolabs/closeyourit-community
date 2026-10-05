# frozen_string_literal: true

# logs_entries and errors_events are monthly-partitioned and large in production (CYRA-750): no step may
# hold a write lock longer than a catalog change (CYRA-914 P7). Indexes are built concurrently on each
# partition and attached to an index made ON ONLY the parent; checks are added NOT VALID and validated
# under SHARE UPDATE EXCLUSIVE, which leaves reads and writes alone. The resulting schema is unchanged.
class AddOtlpLogCorrelation < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Waiting longer than this behind a running query fails the release instead of queueing every write.
  LOCK_TIMEOUT = "5s"

  INDEXES = {
    "logs_entries_span_correlation" => [ :logs_entries, %w[project_id trace_id span_id] ],
    "logs_entries_error_identity" => [ :logs_entries, %w[project_id error_event_id] ],
    "errors_events_span_correlation" => [ :errors_events, %w[project_id trace_id span_id] ]
  }.freeze

  CHECKS = {
    "logs_valid_otlp_severity" => "severity_number IS NULL OR severity_number BETWEEN 0 AND 24",
    "logs_valid_event_time_unix_nano" =>
      "event_time_unix_nano IS NULL OR event_time_unix_nano BETWEEN 0 AND 18446744073709551615",
    "logs_valid_observed_time_unix_nano" =>
      "observed_time_unix_nano IS NULL OR observed_time_unix_nano BETWEEN 0 AND 18446744073709551615"
  }.freeze

  def up
    execute "SET lock_timeout = '#{LOCK_TIMEOUT}'"
    add_column :logs_entries, :signal_source, :string, null: false, default: "native", if_not_exists: true
    add_column :logs_entries, :severity_number, :integer, if_not_exists: true
    add_column :logs_entries, :severity_text, :string, if_not_exists: true
    add_column :logs_entries, :span_id, :string, limit: 16, if_not_exists: true
    add_column :logs_entries, :event_time_unix_nano, :decimal, precision: 20, scale: 0, if_not_exists: true
    add_column :logs_entries, :observed_time_unix_nano, :decimal, precision: 20, scale: 0, if_not_exists: true
    add_column :logs_entries, :otlp_payload, :jsonb, null: false, default: {}, if_not_exists: true
    add_column :logs_entries, :payload_digest, :string, limit: 64, if_not_exists: true
    add_column :logs_entries, :error_event_id, :string, if_not_exists: true
    add_column :errors_events, :span_id, :string, limit: 16, if_not_exists: true

    CHECKS.each do |name, expression|
      next if check_constraint_exists?(:logs_entries, name: name)

      add_check_constraint :logs_entries, expression, name: name, validate: false
    end
    execute "RESET lock_timeout"

    INDEXES.each { |name, (table, columns)| add_partitioned_index(table, name, columns) }
    CHECKS.each_key { |name| validate_check_constraint :logs_entries, name: name }
  end

  def down
    INDEXES.each { |name, (table, _)| remove_index table, name: name, if_exists: true }
    CHECKS.each_key { |name| remove_check_constraint :logs_entries, name: name, if_exists: true }
    remove_column :errors_events, :span_id, if_exists: true
    %i[signal_source severity_number severity_text span_id event_time_unix_nano observed_time_unix_nano
       otlp_payload payload_digest error_event_id].each do |column|
      remove_column :logs_entries, column, if_exists: true
    end
  end

  private

  # CREATE INDEX CONCURRENTLY does not work on a partitioned table: the parent index starts invalid ON ONLY
  # the parent and becomes valid once every partition has attached its own. New partitions get it by themselves.
  def add_partitioned_index(table, name, columns)
    column_list = columns.map { |column| quote_column_name(column) }.join(", ")
    execute "CREATE INDEX IF NOT EXISTS #{quote_column_name(name)} ON ONLY #{quote_table_name(table)} (#{column_list})"
    partitions(table).each do |partition|
      child = "#{name}_#{partition}"
      execute "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{quote_column_name(child)} " \
              "ON #{quote_table_name(partition)} (#{column_list})"
      next if attached?(child)

      execute "ALTER INDEX #{quote_column_name(name)} ATTACH PARTITION #{quote_column_name(child)}"
    end
  end

  def partitions(table)
    select_values(<<~SQL.squish)
      SELECT child.relname FROM pg_inherits
      JOIN pg_class child ON child.oid = pg_inherits.inhrelid
      WHERE pg_inherits.inhparent = #{quote(table.to_s)}::regclass
      ORDER BY child.relname
    SQL
  end

  def attached?(index)
    select_value("SELECT 1 FROM pg_inherits WHERE inhrelid = #{quote(index)}::regclass").present?
  end
end
