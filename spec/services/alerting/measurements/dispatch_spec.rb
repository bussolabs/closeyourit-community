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

  it "delivers in-app only for the exact evaluated rule and deduplicates retries" do
    account
    other = create(:alerting_rule, organization: project.organization, project: project, event_type: :measurement_threshold, measurement_series: series, measurement_config: config)
    travel_to ending + 31.seconds do
      evaluation = Alerting::Measurements::Evaluate.call(rule_id: rule.id, window_end: ending)
      described_class.call(evaluation_id: evaluation.id)
      described_class.call(evaluation_id: evaluation.id)
      notifications = Alerting::Notification.where(event_type: :measurement_threshold)
      expect(notifications.count).to eq(1)
      expect(notifications.sole).to have_attributes(rule_id: rule.id, account_id: account.id, via: "in_app", status: "sent")
      expect(other.notifications).to be_empty
      expect(evaluation.reload.dispatch_state).to eq("delivered")
    end
  end

  it "cancels a pending dispatch after the rule is edited or disabled" do
    account
    travel_to ending + 31.seconds do
      evaluation = Alerting::Measurements::Evaluate.call(rule_id: rule.id, window_end: ending)
      rule.update!(measurement_config: config.merge("threshold" => "20"))
      described_class.call(evaluation_id: evaluation.id)
      expect(evaluation.reload.dispatch_state).to eq("cancelled")
      expect(Alerting::Notification.where(event_type: :measurement_threshold)).to be_empty
    end
  end

  it "leaves a durable pending row when enqueue fails and recovers through scheduling" do
    travel_to ending + 31.seconds do
      allow(Alerting::Measurements::DispatchJob).to receive(:perform_later).and_raise(ActiveJob::EnqueueError, "Queue unavailable")
      expect { Alerting::Measurements::Evaluate.call(rule_id: rule.id, window_end: ending) }.to raise_error(ActiveJob::EnqueueError)
      evaluation = Alerting::Evaluation.find_by!(rule_id: rule.id)
      expect(evaluation.dispatch_state).to eq("pending")
      allow(Alerting::Measurements::DispatchJob).to receive(:perform_later).and_call_original
      expect { Alerting::Measurements::ScheduleJob.perform_now }.to have_enqueued_job(Alerting::Measurements::DispatchJob).with(evaluation_id: evaluation.id)
    end
  end
end
