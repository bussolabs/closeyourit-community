# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::PruneJob, type: :job do
  let(:project) { create(:project) }

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
