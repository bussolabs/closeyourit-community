# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Measurements::PruneJob do
  it "deletes bounded expired batches and schedules continuation without scheduling new evaluations" do
    project = create(:project)
    rule = create(:alerting_rule, project: project, organization: project.organization)
    rows = 1001.times.map do |index|
      { rule_id: rule.id, project_id: project.id, series_id: SecureRandom.uuid, config_digest: "a" * 64,
        window_end_ns: index, status: "unknown", result: {}, created_at: 31.days.ago, updated_at: 31.days.ago }
    end
    Alerting::Evaluation.insert_all!(rows)
    expect { described_class.perform_now }.to have_enqueued_job(described_class)
    expect(Alerting::Evaluation.where(rule_id: rule.id).count).to eq(1)
    expect(Alerting::Measurements::EvaluateJob).not_to have_been_enqueued
    described_class.perform_now
    expect(Alerting::Evaluation.where(rule_id: rule.id)).to be_empty
  end
end
