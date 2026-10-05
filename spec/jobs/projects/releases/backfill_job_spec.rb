# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Releases::BackfillJob, type: :job do
  let(:project) { create(:project) }
  let(:sha_full)  { "d3ce2af9b1e04c8a7f6d2e1b0a9c8d7e6f5a4b3c" }
  let(:sha_short) { "d3ce2af" }

  def event_on(group:, release:, environment:)
    create(:error_event, group:, project: group.project, release:, environment:)
  end

  describe "#perform — coppia con match sicuro" do
    it "fonde la release-hash nella release-tag il cui sha inizia per la version" do
      tag = create(:release, project:, version: "v1.0.0", environment: "production", sha: sha_full,
                             events_count: 0)
      sha = create(:release, project:, version: sha_short, environment: "production", sha: nil,
                             events_count: 5)
      group = create(:error_group, project:)
      5.times { event_on(group:, release: sha_short, environment: "production") }

      described_class.perform_now

      expect(Projects::Release.exists?(sha.id)).to be(false)
      expect(tag.reload.events_count).to eq(5)
      expect(Errors::Event.where(project:, release: "v1.0.0").count).to eq(5)
      expect(Errors::Event.where(project:, release: sha_short).count).to eq(0)
    end
  end

  describe "#perform — nessun tag corrispondente" do
    it "lascia intatta la release-hash senza match sullo sha" do
      # Il tag esiste ma il suo sha NON inizia per la version della hash.
      create(:release, project:, version: "v2.0.0", environment: "production", sha: sha_full)
      orphan = create(:release, project:, version: "beef123", environment: "production", sha: nil,
                                events_count: 4)
      group = create(:error_group, project:)
      4.times { event_on(group:, release: "beef123", environment: "production") }

      described_class.perform_now

      expect(Projects::Release.exists?(orphan.id)).to be(true)
      expect(orphan.reload.events_count).to eq(4)
      expect(Errors::Event.where(project:, release: "beef123").count).to eq(4)
    end
  end

  describe "#perform — stesso commit su staging E production" do
    it "fonde ogni hash nel tag del proprio environment, conteggi separati, nessun evento tra ambienti" do
      tag_prod = create(:release, project:, version: "v1.0.0", environment: "production",
                                  sha: sha_full, events_count: 0)
      tag_staging = create(:release, project:, version: "v1.0.0-beta", environment: "staging",
                                     sha: sha_full, events_count: 0)
      hash_prod = create(:release, project:, version: sha_short, environment: "production", sha: nil,
                                   events_count: 5)
      hash_staging = create(:release, project:, version: sha_short, environment: "staging", sha: nil,
                                      events_count: 2)
      group = create(:error_group, project:)
      5.times { event_on(group:, release: sha_short, environment: "production") }
      2.times { event_on(group:, release: sha_short, environment: "staging") }

      described_class.perform_now

      expect(Projects::Release.exists?(hash_prod.id)).to be(false)
      expect(Projects::Release.exists?(hash_staging.id)).to be(false)
      expect(tag_prod.reload.events_count).to eq(5)
      expect(tag_staging.reload.events_count).to eq(2)
      # Nessun evento migrato tra ambienti.
      expect(Errors::Event.where(project:, environment: "production", release: "v1.0.0").count).to eq(5)
      expect(Errors::Event.where(project:, environment: "staging", release: "v1.0.0-beta").count).to eq(2)
    end
  end

  describe "#perform — match ambiguo (uno sha su due tag)" do
    it "salta la coppia, logga un warn e non fonde nulla" do
      tag_one = create(:release, project:, version: "v1.0.0", environment: "production",
                                 sha: "abcdef1111111111111111111111111111111111", events_count: 0)
      tag_two = create(:release, project:, version: "v1.0.1", environment: "production",
                                 sha: "abcdef1222222222222222222222222222222222", events_count: 0)
      ambiguous = create(:release, project:, version: "abcdef1", environment: "production", sha: nil,
                                   events_count: 3)
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now

      expect(Rails.logger).to have_received(:warn).with(a_string_including("abcdef1")).at_least(:once)
      # Niente fusione arbitraria: hash e tag restano tutti.
      expect(Projects::Release.exists?(ambiguous.id)).to be(true)
      expect(ambiguous.reload.events_count).to eq(3)
      expect(tag_one.reload.events_count).to eq(0)
      expect(tag_two.reload.events_count).to eq(0)
    end
  end

  describe "#perform — idempotenza" do
    it "un secondo run non applica alcuna modifica ulteriore" do
      tag = create(:release, project:, version: "v1.0.0", environment: "production", sha: sha_full,
                             events_count: 0)
      create(:release, project:, version: sha_short, environment: "production", sha: nil,
                       events_count: 3)
      group = create(:error_group, project:)
      3.times { event_on(group:, release: sha_short, environment: "production") }

      described_class.perform_now
      after_first = tag.reload.events_count

      expect { described_class.perform_now }.not_to change { tag.reload.events_count }.from(after_first)
      expect(Errors::Event.where(project:, release: "v1.0.0").count).to eq(3)
    end
  end

  describe "#perform(dry_run: true)" do
    it "elenca le coppie senza mutare nulla" do
      tag = create(:release, project:, version: "v1.0.0", environment: "production", sha: sha_full,
                             events_count: 0)
      sha = create(:release, project:, version: sha_short, environment: "production", sha: nil,
                             events_count: 3)
      group = create(:error_group, project:)
      3.times { event_on(group:, release: sha_short, environment: "production") }
      allow(Rails.logger).to receive(:info)

      described_class.perform_now(dry_run: true)

      expect(Rails.logger).to have_received(:info).with(a_string_including("dry_run")).at_least(:once)
      # Nessuna mutazione: la riga hash resta e gli eventi non sono ri-etichettati.
      expect(Projects::Release.exists?(sha.id)).to be(true)
      expect(tag.reload.events_count).to eq(0)
      expect(Errors::Event.where(project:, release: sha_short).count).to eq(3)
      expect(Errors::Event.where(project:, release: "v1.0.0").count).to eq(0)
    end
  end
end
