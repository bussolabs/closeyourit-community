# frozen_string_literal: true

require "rails_helper"

RSpec.describe Metrics::PruneSamplesJob do
  before { Settings::Global.instance.update!(performance_retention_days: 30) }

  it "cancella i sample più vecchi della retention di sistema e tiene i recenti" do
    group = create(:metric_group)
    old = create(:metric_sample, group: group, project: group.project, created_at: 40.days.ago)
    recent = create(:metric_sample, group: group, project: group.project, created_at: 1.day.ago)

    described_class.perform_now

    expect(Metrics::Sample.exists?(old.id)).to be(false)
    expect(Metrics::Sample.exists?(recent.id)).to be(true)
  end

  it "rispetta l'override per-progetto (nearest-wins)" do
    project = create(:project).tap { |p| p.update!(performance_retention_days: 7) }
    group = create(:metric_group, project:)
    old = create(:metric_sample, group:, project:, created_at: 10.days.ago)

    described_class.perform_now

    expect(Metrics::Sample.exists?(old.id)).to be(false)
  end

  it "applica la retention dell'org quando il progetto non ha override" do
    org = create(:organization).tap { |o| o.update!(performance_retention_days: 60) }
    project = create(:project, organization: org)
    group = create(:metric_group, project:)
    borderline = create(:metric_sample, group:, project:, created_at: 61.days.ago)
    fresh = create(:metric_sample, group:, project:, created_at: 5.days.ago)

    described_class.perform_now

    expect(Metrics::Sample.exists?(borderline.id)).to be(false)
    expect(Metrics::Sample.exists?(fresh.id)).to be(true)
  end

  it "non tocca i gruppi (la storia aggregata sopravvive alla potatura)" do
    group = create(:metric_group)
    create(:metric_sample, group: group, project: group.project, created_at: 40.days.ago)

    expect { described_class.perform_now }.not_to change(Metrics::Group, :count)
  end
end
