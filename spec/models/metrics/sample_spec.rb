# frozen_string_literal: true

require "rails_helper"

RSpec.describe Metrics::Sample, type: :model do
  it "richiede sample_id, occurred_at e duration_ms" do
    sample = build(:metric_sample, sample_id: nil, occurred_at: nil, duration_ms: nil)
    expect(sample).not_to be_valid
    expect(sample.errors[:sample_id]).to be_present
    expect(sample.errors[:occurred_at]).to be_present
    expect(sample.errors[:duration_ms]).to be_present
  end

  it "ha sample_id unico per progetto (idempotenza at-least-once)" do
    existing = create(:metric_sample)
    dup = build(:metric_sample, project: existing.project, group: existing.group, sample_id: existing.sample_id)
    expect(dup).not_to be_valid
  end

  it "appartiene a un group e a un project" do
    sample = create(:metric_sample)
    expect(sample.group).to be_a(Metrics::Group)
    expect(sample.project).to be_a(Projects::Project)
  end
end
