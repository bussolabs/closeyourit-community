# frozen_string_literal: true

abort "Use the dedicated benchmark test slot" unless ENV["TEST_SLOT"] == "_cyra1231_benchmark"
require "rails_helper"
require "etc"

# Opt-in PostgreSQL workload; run explicitly as documented in docs/measurement-benchmark.md.
RSpec.describe "Measurement history benchmark", type: :job do
  include ActiveJob::TestHelper

  # Ruby 4 no longer ships the benchmark library by default.
  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end
  def explain(sql)
    JSON.parse(ActiveRecord::Base.connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}")).first
  end

  def scans(plan)
    [ plan, *Array(plan["Plans"]).flat_map { |child| scans(child) } ]
  end

  def seed_history(rule, now)
    connection = ActiveRecord::Base.connection
    connection.execute(<<~SQL)
      INSERT INTO alerting_evaluations
        (rule_id, project_id, series_id, config_digest, window_end_ns, status,
         retry_at, created_at, updated_at)
      SELECT #{connection.quote(rule.id)}, #{connection.quote(rule.project_id)},
        gen_random_uuid(), repeat('a', 64),
        extract(epoch FROM (#{connection.quote(now)}::timestamp - n * interval '1 minute')) * 1000000000,
        'unknown', #{connection.quote(now)}::timestamp - (n - 1) * interval '1 minute',
        #{connection.quote(now)}::timestamp - n * interval '1 minute', #{connection.quote(now)}
      FROM generate_series(1, 43200) AS n
    SQL
  end

  [ 10, 100 ].each do |rule_count|
    it "measures #{rule_count} rules with thirty days of per-minute unknown evaluations" do
      expect(ENV.fetch("TEST_SLOT")).to eq("_cyra1231_benchmark")
      now = Time.utc(2026, 11, 23, 12)
      travel_to now do
        project = create(:project)
        rules = Array.new(rule_count) do
          rule = create(:alerting_rule, project: project, organization: project.organization)
          # Retained rules may have lost their series; they must still be scheduled (CYRA-1231).
          rule.update_columns(event_type: Alerting::Rule.event_types.fetch("measurement_threshold"))
          seed_history(rule, now)
          rule
        end
        oldest = Alerting::Evaluation.order(:created_at).limit(2001).to_a
        Alerting::Evaluation.where(id: oldest.map(&:id)).update_all(created_at: now - 31.days)
        ActiveRecord::Base.connection.execute("ANALYZE alerting_evaluations")
        ActiveRecord::Base.connection.execute("ANALYZE alerting_rules")

        queries = []
        subscriber = lambda do |*args|
          payload = args.last
          queries << payload[:sql] if payload[:sql].start_with?("SELECT") && payload[:sql].include?("alerting_")
        end
        rounds = Array.new(5) do
          clear_enqueued_jobs
          elapsed do
            ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
              # Include scheduling continuation; evaluation and delivery remain queued.
              perform_enqueued_jobs(only: Alerting::Measurements::ScheduleJob) do
                Alerting::Measurements::ScheduleJob.perform_later
              end
            end
          end
        end
        expect(enqueued_jobs.count { |job| job[:job] == Alerting::Measurements::EvaluateJob })
          .to eq(rule_count + [ rule_count * 5, 100 ].min)
        retry_sql = Alerting::Evaluation.where(status: "unknown", retry_at: ..now)
          .where("window_end_ns >= ?", ((now - 5.minutes).to_i * 1_000_000_000).to_s)
          .order(:retry_at).limit(100).select(:rule_id, :window_end_ns, :config_digest).to_sql
        prune_sql = Alerting::Evaluation.where(created_at: ...30.days.ago)
          .order(:created_at, :id).limit(1000).select(:id).to_sql
        retry_plan = explain(retry_sql)
        prune_plan = explain(prune_sql)
        clear_enqueued_jobs
        prune_seconds = elapsed do
          perform_enqueued_jobs(only: Alerting::Measurements::PruneJob) do
            Alerting::Measurements::PruneJob.perform_later
          end
        end
        report = { rules: rules.size, history_rows: rule_count * 43200,
                   ruby: RUBY_DESCRIPTION, platform: RUBY_PLATFORM, processors: Etc.nprocessors,
                   retry_index: ActiveRecord::Base.connection.indexes("alerting_evaluations")
                     .find { |index| index.name == "index_alerting_evaluations_unknown_by_window_and_retry" }&.columns,
                   postgres: ActiveRecord::Base.connection.select_value("SELECT version()"),
                   schedule_seconds: rounds, schedule_queries: queries.uniq,
                   retry: retry_plan, prune: prune_plan, prune_seconds: prune_seconds }
        FileUtils.mkdir_p(Rails.root.join("tmp/measurement-benchmark"))
        File.write(Rails.root.join("tmp/measurement-benchmark/#{rule_count}.json"), JSON.pretty_generate(report))

        expect(rounds.max).to be < 1.0
        expect(Alerting::Evaluation.where(created_at: ...30.days.ago)).to be_empty
        expect(Alerting::Evaluation.count).to eq(rule_count * 43200 - 2001)
        [ retry_plan, prune_plan ].each do |plan|
          table_scans = scans(plan.fetch("Plan")).select { |node| node["Relation Name"] == "alerting_evaluations" }
          expect(table_scans).not_to be_empty
          expect(table_scans.map { |node| node["Node Type"] }).not_to include("Seq Scan")
          expect(table_scans.sum { |node| (node["Actual Rows"] + node.fetch("Rows Removed by Filter", 0)) * node["Actual Loops"] })
            .to be < 10_000
        end
      end
    end
  end
end
