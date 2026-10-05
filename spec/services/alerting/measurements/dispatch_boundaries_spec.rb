# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Measurements::Dispatch do
  let(:project) { create(:project) }
  let(:account) do
    create(:account).tap do |actor|
      create(:membership, account: actor, organization: project.organization, role: :owner)
      create(:alerting_preference, account: actor, organization: project.organization, email_enabled: false, telegram_enabled: false)
    end
  end
  let(:ending) { Time.utc(2026, 10, 4, 12, 1) }
  let(:series) do
    Measurements::Ingest::Record.call(project: project, payload: { "resourceMetrics" => [ { "scopeMetrics" => [ { "metrics" => [ {
      "name" => "load", "gauge" => { "dataPoints" => [ { "timeUnixNano" => ((ending.to_i - 1) * 1_000_000_000).to_s, "asInt" => "10" } ] }
    } ] } ] } ] })
    project.measurement_series.sole
  end
  let(:config) { { "version" => 1, "statistic" => "last", "comparison" => "gt", "threshold" => "5", "window_seconds" => 60 } }
  let(:rule) { create(:alerting_rule, organization: project.organization, project: project, event_type: :measurement_threshold, measurement_series: series, measurement_config: config) }

  it "does nothing for an absent evaluation" do
    expect(described_class.call(evaluation_id: SecureRandom.uuid)).to be_nil
  end

  it "respects an active delivery lease and reclaims it only after expiry" do
    account
    travel_to ending + 31.seconds do
      evaluation = Alerting::Measurements::Evaluate.call(rule_id: rule.id, window_end: ending)
      evaluation.update!(dispatch_state: "delivering", dispatch_until: 1.minute.from_now)
      expect(described_class.call(evaluation_id: evaluation.id)).to be_nil
      expect(evaluation.reload.dispatch_state).to eq("delivering")
      expect(Alerting::Notification.where(event_type: :measurement_threshold)).to be_empty
      evaluation.update!(dispatch_until: 1.second.ago)
      described_class.call(evaluation_id: evaluation.id)
      expect(evaluation.reload.dispatch_state).to eq("delivered")
      expect(Alerting::Notification.where(event_type: :measurement_threshold).count).to eq(1)
    end
  end

  it "cancels stale delivery after the rule recovers or moves to a newer window" do
    travel_to ending + 31.seconds do
      evaluation = Alerting::Measurements::Evaluate.call(rule_id: rule.id, window_end: ending)
      rule.update_columns(measurement_state: rule.reload.measurement_state.merge("state" => "safe"))
      expect(described_class.current?(evaluation, rule)).to be(false)
      rule.update_columns(measurement_state: rule.measurement_state.merge("state" => "firing", "window_end_ns" => ((ending.to_i + 60) * 1_000_000_000).to_s))
      expect(described_class.current?(evaluation, rule)).to be(false)
      described_class.call(evaluation_id: evaluation.id)
      expect(evaluation.reload.dispatch_state).to eq("cancelled")
    end
  end
end
