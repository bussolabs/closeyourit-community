# frozen_string_literal: true

module PruningQueryPlans
  # Replay the actual bound statements from the same starting data. EXPLAIN ANALYZE executes
  # deletions, so both the capture and replay are rolled back inside the isolated test database.
  def pruning_plans(table)
    connection = ActiveRecord::Base.connection
    statements = []
    capture = lambda do |*, payload|
      sql = payload[:sql]
      if sql.match?(/\A(?:SELECT|DELETE)\b/) && sql.include?(%Q("#{table}"))
        statements << [ sql, payload[:binds].map(&:value_for_database) ]
      end
    end
    connection.transaction(requires_new: true) do
      ActiveSupport::Notifications.subscribed(capture, "sql.active_record") { yield }
      raise ActiveRecord::Rollback
    end

    plans = []
    connection.transaction(requires_new: true) do
      statements.each do |sql, binds|
        result = connection.raw_connection.exec_params("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}", binds)
        plans << [ sql, JSON.parse(result.getvalue(0, 0)).first.fetch("Plan") ]
      end
      raise ActiveRecord::Rollback
    end
    plans.each do |sql, plan|
      blocks = plan.fetch("Shared Hit Blocks", 0) + plan.fetch("Shared Read Blocks", 0)
      RSpec.configuration.reporter.message("#{table} #{sql.split.first}: #{plan.fetch('Actual Total Time')}ms, #{blocks} blocks")
    end
    plans
  end

  def plan_nodes(plan)
    [ plan ] + plan.fetch("Plans", []).flat_map { |child| plan_nodes(child) }
  end

  def expect_bounded_pruning(plans)
    selections = plans.select { |sql, _| sql.start_with?("SELECT") }
    deletions = plans.select { |sql, _| sql.start_with?("DELETE") }
    expect(selections.size).to eq(3)
    expect(deletions.size).to eq(2)
    expect(selections.last.last.fetch("Actual Rows")).to eq(0)
    plans.each do |sql, plan|
      aggregate_failures(sql) do
        plan_nodes(plan).each do |node|
          expect(node.fetch("Node Type")).not_to eq("Seq Scan")
          visited = node.fetch("Actual Rows", 0) + node.fetch("Rows Removed by Filter", 0)
          expect(visited * node.fetch("Actual Loops", 1)).to be <= 2_000
        end
        expect(plan.fetch("Shared Hit Blocks", 0) + plan.fetch("Shared Read Blocks", 0)).to be < 10_000
      end
    end
  end
end

RSpec.configure { |config| config.include PruningQueryPlans }
