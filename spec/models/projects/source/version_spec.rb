# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Source::Version, type: :model do
  let(:source) { create(:project_source) }

  describe "validazioni" do
    it "version unica per fonte" do
      create(:project_source_version, source:, version: "0.4.0")
      dup = build(:project_source_version, source:, version: "0.4.0")
      expect(dup).not_to be_valid
      expect(build(:project_source_version, source:, version: "0.5.0")).to be_valid
    end

    it "stessa version su fonti diverse è ammessa" do
      create(:project_source_version, source:, version: "0.4.0")
      expect(build(:project_source_version, version: "0.4.0")).to be_valid
    end

    it "version obbligatoria" do
      expect(build(:project_source_version, source:, version: nil)).not_to be_valid
    end

    it "normalizza version (strip)" do
      version = create(:project_source_version, source:, version: "  0.4.0  ")
      expect(version.version).to eq("0.4.0")
    end
  end

  describe ".chronological" do
    it "ordina dalla prima comparsa in poi" do
      recent = create(:project_source_version, source:, version: "0.5.0", first_seen_at: 1.day.ago)
      old    = create(:project_source_version, source:, version: "0.4.0", first_seen_at: 10.days.ago)

      expect(source.versions.chronological.to_a).to eq([ old, recent ])
    end
  end

  describe "cascata alla cancellazione della fonte" do
    it "le versioni muoiono con la fonte" do
      create(:project_source_version, source:, version: "0.4.0")
      expect { source.destroy }.to change(described_class, :count).by(-1)
    end
  end
end
