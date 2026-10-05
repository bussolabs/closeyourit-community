# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Measurements::Evaluate do
  let(:project) { create(:project) }
  let(:ending) { Time.utc(2026, 10, 4, 12, 1) }
  let(:series) do
    Measurements::Ingest::Record.call(project: project, payload: { "resourceMetrics" => [ { "scopeMetrics" => [ { "metrics" => [ {
      "name" => "temperature", "unit" => "Cel", "gauge" => { "dataPoints" => [ { "timeUnixNano" => ((ending.to_i - 1) * 1_000_000_000).to_s, "asInt" => "10" } ] }
    } ] } ] } ] })
    project.measurement_series.sole
  end
  let(:config) { { "version" => 1, "statistic" => "last", "comparison" => "gt", "threshold" => "5", "window_seconds" => 60 } }
  let(:rule) { create(:alerting_rule, organization: project.organization, project: project, event_type: :measurement_threshold, measurement_series: series, measurement_config: config) }

  it "rejects fractional closed-window timestamps before querying or persisting" do
    travel_to ending + 31.seconds do
      expect(described_class.call(rule_id: rule.id, window_end: ending + 0.1)).to be_nil
      expect(Alerting::Evaluation.where(rule_id: rule.id)).to be_empty
    end
  end

  it "records a firing result once and enqueues only that rule's pending dispatch" do
    travel_to ending + 31.seconds do
      first = described_class.call(rule_id: rule.id, window_end: ending)
      repeated = described_class.call(rule_id: rule.id, window_end: ending)
      expect(first.id).to eq(repeated.id)
      expect(first).to have_attributes(status: "firing", dispatch_state: "pending")
      expect(first.result).to include("value" => "10", "unit" => "Cel")
      expect(rule.reload.measurement_state).to include("state" => "firing")
      expect(Alerting::Evaluation.where(rule_id: rule.id).count).to eq(1)
    end
  end

  it "keeps unknown data distinct from a known zero and never recovers on a missing window" do
    travel_to ending + 31.seconds do
      described_class.call(rule_id: rule.id, window_end: ending)
    end
    travel_to ending + 91.seconds do
      missing = described_class.call(rule_id: rule.id, window_end: ending + 60.seconds)
      expect(missing).to have_attributes(status: "unknown", dispatch_state: "none")
      expect(rule.reload.measurement_state["state"]).to eq("firing")
      series.points.create!(project_id: project.id, start_time_unix_nano: 0,
        time_unix_nano: (ending.to_i + 59) * 1_000_000_000,
        payload: { "startTimeUnixNano" => "0", "timeUnixNano" => ((ending.to_i + 59) * 1_000_000_000).to_s, "asInt" => "0" },
        payload_digest: "a" * 64, first_received_at: Time.current)
      safe = described_class.call(rule_id: rule.id, window_end: ending + 60.seconds)
      expect(safe.status).to eq("safe")
      expect(rule.reload.measurement_state["state"]).to eq("safe")
    end
  end

  it "does not let an old window or edited configuration overwrite a newer state" do
    travel_to ending + 31.seconds do
      series.points.create!(project_id: project.id, start_time_unix_nano: 0,
        time_unix_nano: (ending.to_i - 61) * 1_000_000_000,
        payload: { "startTimeUnixNano" => "0", "timeUnixNano" => ((ending.to_i - 61) * 1_000_000_000).to_s, "asInt" => "10" },
        payload_digest: "b" * 64, first_received_at: Time.current)
      described_class.call(rule_id: rule.id, window_end: ending)
      older = described_class.call(rule_id: rule.id, window_end: ending - 60.seconds)
      expect(older).to have_attributes(status: "firing", dispatch_state: "none")
      expect(rule.reload.measurement_state["window_end_ns"]).to eq((ending.to_i * 1_000_000_000).to_s)
      original = Alerting::Measurements::Configuration.digest(rule)
      rule.update!(measurement_config: config.merge("threshold" => "20"))
      expect(described_class.call(rule_id: rule.id, window_end: ending, config_digest: original)).to be_nil
      changed = described_class.call(rule_id: rule.id, window_end: ending - 60.seconds)
      expect(changed).to have_attributes(status: "safe", dispatch_state: "none")
      expect(rule.reload.measurement_state["state"]).to eq("firing")
      expect(rule.reload.measurement_state["window_end_ns"]).to eq((ending.to_i * 1_000_000_000).to_s)
      rule.update!(enabled: false)
      expect(described_class.call(rule_id: rule.id, window_end: ending)).to be_nil
    end
  end
end
