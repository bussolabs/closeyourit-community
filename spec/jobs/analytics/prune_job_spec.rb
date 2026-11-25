# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::PruneJob, type: :job do
  let(:project) { create(:project) }

  it "handles empty measurements" do
    project
    expect { described_class.perform_now }.not_to change(Analytics::WebVital, :count)
  end

  it "uses each project's inclusive arrival cutoff regardless of visitor timestamps" do
    travel_to(Time.utc(2026, 6, 1, 12)) do
      short = create(:project, analytics_retention_days: 7)
      long = create(:project, analytics_retention_days: 30)
      expired = create(:web_vital, project: short, created_at: 7.days.ago, occurred_at: 1.day.from_now)
      recent = create(:web_vital, project: short, created_at: 7.days.ago + 1.second, occurred_at: 90.days.ago)
      retained = create(:web_vital, project: long, created_at: 7.days.ago, occurred_at: 90.days.ago)
      boundary = create(:web_vital, project: long, created_at: 30.days.ago, occurred_at: 1.day.from_now)

      described_class.perform_now

      expect(Analytics::WebVital.where(id: [ expired.id, boundary.id ])).to be_empty
      expect(Analytics::WebVital.pluck(:id)).to match_array([ recent.id, retained.id ])
    end
  end

  it "deletes multiple tied batches without losing the boundary" do
    travel_to(Time.utc(2026, 6, 1, 12)) do
      project.update!(analytics_retention_days: 7)
      template = create(:web_vital, project:, created_at: 7.days.ago)
      attributes = template.attributes.except("id", "event_id")
      Analytics::WebVital.insert_all!(Array.new(2_000) { attributes.merge("event_id" => SecureRandom.uuid) })
      fresh = create(:web_vital, project:, created_at: 7.days.ago + 1.second)

      described_class.perform_now

      expect(Analytics::WebVital.pluck(:id)).to eq([ fresh.id ])
    end
  end

  it "bounds every measurement query in a mostly recent project" do
    project.update!(analytics_retention_days: 7)
    template = create(:web_vital, project:, created_at: 1.day.ago)
    attributes = template.attributes.except("id", "event_id")
    Analytics::WebVital.insert_all!(Array.new(100_000) { attributes.merge("event_id" => SecureRandom.uuid) })
    Analytics::WebVital.insert_all!(Array.new(2_000) do
      attributes.merge("event_id" => SecureRandom.uuid, "created_at" => 8.days.ago)
    end)
    ActiveRecord::Base.connection.execute("ANALYZE analytics_web_vitals")

    expect_bounded_pruning(pruning_plans("analytics_web_vitals") { described_class.perform_now })
  end

  it "pota i pageview oltre la retention risolta e conserva i recenti" do
    old = create(:pageview, project:)
    old.update_column(:created_at, (Analytics::Constants::RETENTION_DEFAULT_DAYS + 1).days.ago)
    fresh = create(:pageview, project:)

    described_class.perform_now

    expect(Analytics::Pageview.exists?(old.id)).to be(false)
    expect(Analytics::Pageview.exists?(fresh.id)).to be(true)
  end

  # CYRA-538 — le misure di velocità nascono dallo stesso visitatore dei pageview: due durate di
  # conservazione diverse per lo stesso dato sarebbero un modo per ritrovarsi in casa qualcosa che
  # non si doveva più avere.
  it "pota le misure di velocità con la stessa finestra dei pageview" do
    vecchia = create(:web_vital, project:)
    vecchia.update_column(:created_at, (Analytics::Constants::RETENTION_DEFAULT_DAYS + 1).days.ago)
    recente = create(:web_vital, project:)

    described_class.perform_now

    expect(Analytics::WebVital.exists?(vecchia.id)).to be(false)
    expect(Analytics::WebVital.exists?(recente.id)).to be(true)
  end

  it "rispetta l'override di retention del progetto (nearest-wins)" do
    project.update!(analytics_retention_days: 7)
    borderline = create(:pageview, project:)
    borderline.update_column(:created_at, 8.days.ago)

    described_class.perform_now

    expect(Analytics::Pageview.exists?(borderline.id)).to be(false)
  end

  it "distrugge i salt oltre ANALYTICS_SALT_RETENTION_DAYS e conserva quelli recenti" do
    today = Time.current.utc.to_date
    old_salt = create(:analytics_salt, date: today - Analytics::Constants::SALT_RETENTION_DAYS - 1)
    fresh_salt = create(:analytics_salt, date: today)

    described_class.perform_now

    expect(Analytics::Salt.exists?(old_salt.id)).to be(false)
    expect(Analytics::Salt.exists?(fresh_salt.id)).to be(true)
  end
end
