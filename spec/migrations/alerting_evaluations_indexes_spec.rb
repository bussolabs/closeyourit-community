# frozen_string_literal: true

require "rails_helper"

# The per-minute retry lookup and the nightly prune filter evaluations by time across all rules:
# without these indexes every run reads the whole evaluation history (CYRA-1231).
RSpec.describe "Alerting evaluations indexes", type: :model do
  let(:indexes) { ActiveRecord::Base.connection.indexes("alerting_evaluations") }

  it "indexes unknown evaluations by window end for the retry lookup" do
    index = indexes.find { |i| i.name == "index_alerting_evaluations_unknown_by_window_and_retry" }

    expect(index).to be_present
    expect(index.columns).to eq([ "window_end_ns", "retry_at" ])
    expect(index.where).to match(/status.*=.*'unknown'/)
  end

  it "indexes every evaluation by creation time for the prune" do
    index = indexes.find { |i| i.name == "index_alerting_evaluations_on_created_at" }

    expect(index).to be_present
    expect(index.columns).to eq([ "created_at" ])
    expect(index.where).to be_nil
  end

  it "reaches expired rows without scanning the retained history" do
    travel_to Time.utc(2026, 11, 23, 12) do
      project = create(:project)
      rule = create(:alerting_rule, project: project, organization: project.organization)
      20.times do |batch|
        rows = 1000.times.map do |offset|
          index = batch * 1000 + offset
          { rule_id: rule.id, project_id: project.id, series_id: SecureRandom.uuid,
            config_digest: "a" * 64, window_end_ns: index, status: "unknown",
            created_at: index < 10 ? 31.days.ago : 1.day.ago, updated_at: Time.current }
        end
        Alerting::Evaluation.insert_all!(rows)
      end
      connection = ActiveRecord::Base.connection
      connection.execute("ANALYZE alerting_evaluations")
      sql = Alerting::Evaluation.where(created_at: ...30.days.ago)
        .order(:created_at, :id).limit(1000).select(:id).to_sql
      plan = JSON.parse(connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}")).first.fetch("Plan")
      nodes = [ plan ]
      table_scans = []
      until nodes.empty?
        node = nodes.shift
        table_scans << node if node["Relation Name"] == "alerting_evaluations"
        nodes.concat(Array(node["Plans"]))
      end
      expect(table_scans).not_to be_empty
      expect(table_scans.map { |node| node["Node Type"] }).not_to include("Seq Scan")
      expect(table_scans.sum { |node| (node["Actual Rows"] + node.fetch("Rows Removed by Filter", 0)) * node["Actual Loops"] }).to be <= 10
    end
  end
end
