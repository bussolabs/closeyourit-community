# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Measurement evaluation concurrency", :real_concurrency do
  self.use_transactional_tests = false

  it "persists one evaluation and one local notification across independent workers" do
    organization = create(:organization, slug: "measurements-#{SecureRandom.hex(8)}")
    project = create(:project, organization: organization)
    account = create(:account)
    create(:membership, organization: organization, account: account, role: :owner)
    create(:alerting_preference, organization: organization, account: account, email_enabled: false, telegram_enabled: false)
    ending = Time.at(((Time.current - 31.seconds).to_i / 60) * 60).utc
    Measurements::Ingest::Record.call(project: project, payload: { "resourceMetrics" => [ { "scopeMetrics" => [ { "metrics" => [ {
      "name" => "load", "gauge" => { "dataPoints" => [ { "timeUnixNano" => ((ending.to_i - 1) * 1_000_000_000).to_s, "asInt" => "10" } ] }
    } ] } ] } ] })
    series = project.measurement_series.sole
    rule = create(:alerting_rule, organization: organization, project: project, event_type: :measurement_threshold, measurement_series: series,
      measurement_config: { "version" => 1, "statistic" => "last", "comparison" => "gt", "threshold" => "5", "window_seconds" => 60 })
    ready, proceed = Queue.new, Queue.new
    threads = 2.times.map do
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          ready << true
          proceed.pop
          evaluation = Alerting::Measurements::Evaluate.call(rule_id: rule.id, window_end: ending)
          Alerting::Measurements::Dispatch.call(evaluation_id: evaluation.id)
          evaluation.id
        end
      end
    end
    Timeout.timeout(5) { 2.times { ready.pop } }
    2.times { proceed << true }
    expect(threads.map(&:value).uniq.size).to eq(1)
    expect(Alerting::Evaluation.where(rule_id: rule.id).count).to eq(1)
    expect(rule.notifications.where(via: :in_app).count).to eq(1)
    expect(rule.notifications.where.not(via: :in_app)).to be_empty
  ensure
    2.times { proceed << true } if proceed
    threads&.each(&:join)
    organization&.destroy!
    account&.destroy!
  end
end
