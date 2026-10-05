# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Releases::Merge do
  let(:project) { create(:project) }
  # SHA a 40 char (colonna sha della release-tag da CI) e il suo prefisso a 7 char
  # (la version SHA-shaped della release-hash da ingest).
  let(:sha_full)  { "d3ce2af9b1e04c8a7f6d2e1b0a9c8d7e6f5a4b3c" }
  let(:sha_short) { "d3ce2af" }

  def event_on(group:, release:, environment:)
    create(:error_event, group:, project: group.project, release:, environment:)
  end

  describe "#call — fusione di una coppia" do
    it "ri-etichetta gli eventi dalla version hash a quella tag e somma i contatori" do
      tag = create(:release, project:, version: "v1.0.0", environment: "production", sha: sha_full,
                             events_count: 0, first_event_at: nil, last_event_at: nil)
      sha = create(:release, project:, version: sha_short, environment: "production", sha: nil,
                             events_count: 3,
                             first_event_at: Time.utc(2026, 7, 1, 10),
                             last_event_at: Time.utc(2026, 7, 1, 12))
      group = create(:error_group, project:)
      3.times { event_on(group:, release: sha_short, environment: "production") }

      result = described_class.call(tag_release: tag, sha_release: sha)

      expect(result).to be_ok
      expect(result.value).to eq(tag.reload)
      expect(Errors::Event.where(project:, release: "v1.0.0").count).to eq(3)
      expect(Errors::Event.where(project:, release: sha_short).count).to eq(0)
      expect(tag.reload.events_count).to eq(3)
      # La riga hash è stata rimossa, la riga tag sopravvive.
      expect(Projects::Release.exists?(sha.id)).to be(false)
      expect(Projects::Release.exists?(tag.id)).to be(true)
    end

    it "SOMMA i contatori quando la release-tag ne ha già (retention: la COUNT sottostimerebbe)" do
      tag = create(:release, project:, version: "v1.0.0", environment: "production", sha: sha_full,
                             events_count: 10,
                             first_event_at: Time.utc(2026, 7, 1, 9),
                             last_event_at: Time.utc(2026, 7, 1, 11))
      sha = create(:release, project:, version: sha_short, environment: "production", sha: nil,
                             events_count: 3,
                             first_event_at: Time.utc(2026, 7, 1, 8),
                             last_event_at: Time.utc(2026, 7, 1, 12))

      described_class.call(tag_release: tag, sha_release: sha)

      # 10 esistenti (eventi già potati) + 3 nuovi: la somma non regredisce.
      expect(tag.reload.events_count).to eq(13)
      # first_event_at = min, last_event_at = max.
      expect(tag.first_event_at).to eq(Time.utc(2026, 7, 1, 8))
      expect(tag.last_event_at).to eq(Time.utc(2026, 7, 1, 12))
    end

    it "gestisce i first/last_event_at nil sui due lati come track_event!" do
      tag = create(:release, project:, version: "v1.0.0", environment: "production", sha: sha_full,
                             events_count: 0, first_event_at: nil, last_event_at: nil)
      sha = create(:release, project:, version: sha_short, environment: "production", sha: nil,
                             events_count: 2,
                             first_event_at: Time.utc(2026, 7, 1, 8),
                             last_event_at: Time.utc(2026, 7, 1, 9))

      described_class.call(tag_release: tag, sha_release: sha)

      expect(tag.reload.first_event_at).to eq(Time.utc(2026, 7, 1, 8))
      expect(tag.last_event_at).to eq(Time.utc(2026, 7, 1, 9))
    end
  end

  describe "#call — confine environment sugli eventi" do
    it "tocca solo gli eventi dell'environment della release-tag, non gli altri ambienti" do
      tag = create(:release, project:, version: "v1.0.0", environment: "production", sha: sha_full,
                             events_count: 0)
      sha = create(:release, project:, version: sha_short, environment: "production", sha: nil,
                             events_count: 1)
      group = create(:error_group, project:)
      prod_event    = event_on(group:, release: sha_short, environment: "production")
      staging_event = event_on(group:, release: sha_short, environment: "staging")

      described_class.call(tag_release: tag, sha_release: sha)

      expect(prod_event.reload.release).to eq("v1.0.0")
      # Stesso commit su staging: NON ri-etichettato dalla merge production.
      expect(staging_event.reload.release).to eq(sha_short)
    end
  end

  describe "#call — logs_entries" do
    it "ri-etichetta i log della version hash filtrando per project + environment" do
      tag = create(:release, project:, version: "v1.0.0", environment: "production", sha: sha_full)
      sha = create(:release, project:, version: sha_short, environment: "production", sha: nil)
      prod_log    = create(:log_entry, project:, release: sha_short, environment: "production")
      staging_log = create(:log_entry, project:, release: sha_short, environment: "staging")
      other_log   = create(:log_entry, project:, release: "other", environment: "production")

      described_class.call(tag_release: tag, sha_release: sha)

      expect(prod_log.reload.release).to eq("v1.0.0")
      expect(staging_log.reload.release).to eq(sha_short)   # confine environment
      expect(other_log.reload.release).to eq("other")       # confine release
    end
  end

  describe "#call — errors_groups (nessuna colonna environment: filtro per project + release)" do
    it "ri-etichetta tutte e 4 le colonne release del gruppo" do
      tag = create(:release, project:, version: "v1.0.0", environment: "production", sha: sha_full)
      sha = create(:release, project:, version: sha_short, environment: "production", sha: nil)
      group = create(:error_group, project:, release: sha_short, first_seen_release: sha_short,
                                   regressed_in_release: sha_short, resolved_in_release: sha_short)

      described_class.call(tag_release: tag, sha_release: sha)

      group.reload
      expect(group.release).to eq("v1.0.0")
      expect(group.first_seen_release).to eq("v1.0.0")
      expect(group.regressed_in_release).to eq("v1.0.0")
      expect(group.resolved_in_release).to eq("v1.0.0")
    end

    it "non tocca i gruppi di un altro progetto né quelli con release diversa" do
      other_project = create(:project)
      tag = create(:release, project:, version: "v1.0.0", environment: "production", sha: sha_full)
      sha = create(:release, project:, version: sha_short, environment: "production", sha: nil)
      foreign_group = create(:error_group, project: other_project, release: sha_short)
      other_release_group = create(:error_group, project:, release: "abc1234")

      described_class.call(tag_release: tag, sha_release: sha)

      expect(foreign_group.reload.release).to eq(sha_short)       # confine project
      expect(other_release_group.reload.release).to eq("abc1234") # confine release
    end
  end

  describe "#call — idempotenza" do
    it "un secondo call sulla stessa coppia è un no-op sicuro (riga hash già eliminata)" do
      tag = create(:release, project:, version: "v1.0.0", environment: "production", sha: sha_full,
                             events_count: 0)
      sha = create(:release, project:, version: sha_short, environment: "production", sha: nil,
                             events_count: 3)
      group = create(:error_group, project:)
      3.times { event_on(group:, release: sha_short, environment: "production") }

      described_class.call(tag_release: tag, sha_release: sha)
      first_count = tag.reload.events_count

      result = described_class.call(tag_release: tag, sha_release: sha)

      expect(result).to be_ok
      # Nessun doppio conteggio: la seconda fusione non trova più la riga hash.
      expect(tag.reload.events_count).to eq(first_count)
      expect(Errors::Event.where(project:, release: "v1.0.0").count).to eq(3)
    end
  end
end
