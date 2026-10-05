# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::Pageview, type: :model do
  it "factory valida" do
    expect(build(:pageview)).to be_valid
  end

  it "richiede visitor_hash, hostname, path e occurred_at" do
    %i[visitor_hash hostname path occurred_at].each do |field|
      record = build(:pageview, field => nil)
      expect(record).not_to be_valid
      expect(record.errors[field]).to be_present
    end
  end

  it "event_id unico per progetto, riusabile tra progetti diversi" do
    existing = create(:pageview, event_id: "pv-1")
    expect(build(:pageview, project: existing.project, event_id: "pv-1")).not_to be_valid
    expect(build(:pageview, event_id: "pv-1")).to be_valid
  end

  it ".recent ordina per occurred_at discendente con tie-break su id" do
    old = create(:pageview, occurred_at: 2.hours.ago)
    new = create(:pageview, occurred_at: 1.minute.ago)
    expect(described_class.recent.first).to eq(new)
    expect(described_class.recent.last).to eq(old)
  end

  describe ".for_range" do
    let(:now) { Time.zone.local(2026, 9, 30, 12) }

    it "bounds the range by created_at so old monthly partitions are skipped (CYRA-891)" do
      sql = described_class.for_range(SecureRandom.uuid, "24h", environment: nil, now:).to_sql

      expect(sql).to include('"created_at" >=')
    end

    it "keeps a pageview from a client whose clock runs ahead" do
      pageview = create(:pageview, occurred_at: now - 1.hour, created_at: now - 110.minutes)

      expect(described_class.for_range(pageview.project_id, "24h", environment: nil, now:)).to include(pageview)
    end
  end

  it "la cancellazione del progetto elimina i pageview (delete_all + FK cascade)" do
    pageview = create(:pageview)
    expect { pageview.project.destroy! }.to change(described_class, :count).by(-1)
  end
end
