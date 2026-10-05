# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Release, type: :model do
  let(:project) { create(:project) }

  describe "validazioni" do
    it "version unica per [progetto, environment]" do
      create(:release, project:, version: "v1.0.0", environment: "production")
      dup = build(:release, project:, version: "v1.0.0", environment: "production")
      expect(dup).not_to be_valid
      expect(build(:release, project:, version: "v1.0.1", environment: "production")).to be_valid
    end

    it "stessa version su environment diversi è ammessa (staging ≠ production)" do
      create(:release, project:, version: "v1.0.0", environment: "production")
      expect(build(:release, project:, version: "v1.0.0", environment: "staging")).to be_valid
    end

    it "stessa version su progetti diversi è ammessa" do
      create(:release, project:, version: "v1.0.0")
      expect(build(:release, version: "v1.0.0")).to be_valid
    end

    it "environment obbligatorio" do
      expect(build(:release, project:, environment: "")).not_to be_valid
    end

    it "normalizza environment (strip + downcase)" do
      release = create(:release, project:, environment: "  Staging  ")
      expect(release.environment).to eq("staging")
    end
  end

  # CYRA-9: le release nate dall'ingest portano in `version` la commit SHA del payload SDK; la UI
  # deve mostrarla accorciata, mai i 40 char grezzi. Un tag reale (v1.2.3) resta invariato.
  describe "#version_sha_shaped?" do
    # SHA git = esadecimale lowercase; soglie di lunghezza 7 (min) e 40 (max).
    let(:sha40) { "cf4657cc8b5a2f1e9d3c7b0a6e4d2f8c1b9a0e7d" }

    it "una commit SHA a 40 char è SHA-shaped" do
      expect(build(:release, version: sha40).version_sha_shaped?).to be(true)
    end

    it "una SHA breve di 7 char (soglia minima) è SHA-shaped" do
      expect(build(:release, version: sha40.first(7)).version_sha_shaped?).to be(true)
    end

    it "6 char esadecimali (sotto la soglia minima) NON sono SHA-shaped" do
      expect(build(:release, version: sha40.first(6)).version_sha_shaped?).to be(false)
    end

    it "41 char esadecimali (oltre la soglia massima) NON sono SHA-shaped" do
      expect(build(:release, version: "#{sha40}e").version_sha_shaped?).to be(false)
    end

    it "un tag di versione (v1.2.3) NON è SHA-shaped" do
      expect(build(:release, version: "v1.2.3").version_sha_shaped?).to be(false)
    end

    it "una stringa con caratteri non esadecimali NON è SHA-shaped" do
      expect(build(:release, version: "release-2").version_sha_shaped?).to be(false)
    end

    it "un numero di versione con punti (1.0.0) NON è SHA-shaped" do
      expect(build(:release, version: "1.0.0").version_sha_shaped?).to be(false)
    end
  end

  describe "#display_version" do
    let(:sha40) { "cf4657cc8b5a2f1e9d3c7b0a6e4d2f8c1b9a0e7d" }

    it "accorcia una version SHA-shaped ai primi 7 char" do
      expect(build(:release, version: sha40).display_version).to eq(sha40.first(7))
    end

    it "lascia invariato un tag di versione reale" do
      expect(build(:release, version: "v1.2.3").display_version).to eq("v1.2.3")
    end
  end

  describe ".track_event!" do
    it "crea la release al primo evento con finestra attività e contatore 1" do
      at = Time.utc(2026, 7, 1, 12)
      described_class.track_event!(project:, version: "v2.0.0", environment: "production", occurred_at: at)

      release = project.releases.find_by!(version: "v2.0.0", environment: "production")
      expect(release.events_count).to eq(1)
      expect(release.first_event_at).to be_within(1).of(at)
      expect(release.last_event_at).to be_within(1).of(at)
    end

    it "eventi successivi sullo stesso environment allargano la finestra e incrementano il contatore" do
      early = Time.utc(2026, 7, 1, 10)
      late  = Time.utc(2026, 7, 1, 14)
      described_class.track_event!(project:, version: "v2.0.0", environment: "production", occurred_at: late)
      described_class.track_event!(project:, version: "v2.0.0", environment: "production", occurred_at: early)

      release = project.releases.find_by!(version: "v2.0.0", environment: "production")
      expect(release.events_count).to eq(2)
      expect(release.first_event_at).to be_within(1).of(early)
      expect(release.last_event_at).to be_within(1).of(late)
    end

    it "stessa version, environment diverso → due release distinte" do
      at = Time.utc(2026, 7, 1, 12)
      described_class.track_event!(project:, version: "v3.0.0", environment: "staging", occurred_at: at)
      described_class.track_event!(project:, version: "v3.0.0", environment: "production", occurred_at: at)

      expect(project.releases.where(version: "v3.0.0").pluck(:environment)).to contain_exactly("staging", "production")
    end

    it "environment blank → default 'production'" do
      described_class.track_event!(project:, version: "v4.0.0", environment: nil, occurred_at: Time.current)
      expect(project.releases.find_by!(version: "v4.0.0").environment).to eq("production")
    end

    it "version blank → no-op" do
      expect { described_class.track_event!(project:, version: "", environment: "production", occurred_at: Time.current) }
        .not_to change(described_class, :count)
    end
  end

  # CYRA-44: ordinare due release per decidere se un evento è pre-fix (residuo) o post-fix
  # (regressione). Le stringhe version (SHA o tag misti) non sono confrontabili direttamente.
  describe ".introduced_at" do
    it "ritorna l'istante di prima comparsa (min first_event_at su tutti gli environment)" do
      create(:release, project:, version: "v1.0", environment: "production", first_event_at: Time.utc(2026, 6, 1))
      create(:release, project:, version: "v1.0", environment: "staging",    first_event_at: Time.utc(2026, 5, 1))

      expect(described_class.introduced_at(project:, version: "v1.0")).to be_within(1).of(Time.utc(2026, 5, 1))
    end

    it "usa created_at quando first_event_at è nil" do
      release = create(:release, project:, version: "v9.9", first_event_at: nil)
      expect(described_class.introduced_at(project:, version: "v9.9")).to be_within(1).of(release.created_at)
    end

    it "nil quando la version non ha alcun record release" do
      expect(described_class.introduced_at(project:, version: "v0.0")).to be_nil
    end

    it "nil quando la version è blank" do
      expect(described_class.introduced_at(project:, version: "")).to be_nil
    end
  end

  describe ".at_or_after?" do
    it "uguaglianza esatta della version → true" do
      expect(described_class.at_or_after?(project:, version: "v1.2", reference: "v1.2")).to be(true)
    end

    it "confronto semver: una version precedente → false" do
      expect(described_class.at_or_after?(project:, version: "v1.0", reference: "v1.2")).to be(false)
    end

    it "confronto semver: una version successiva → true" do
      expect(described_class.at_or_after?(project:, version: "v2.0", reference: "v1.2")).to be(true)
    end

    it "confronto semver: patch successiva → true" do
      expect(described_class.at_or_after?(project:, version: "v1.2.1", reference: "v1.2.0")).to be(true)
    end

    it "version o reference blank → nil (indeterminato)" do
      expect(described_class.at_or_after?(project:, version: "", reference: "v1.2")).to be_nil
      expect(described_class.at_or_after?(project:, version: "v1.2", reference: "")).to be_nil
    end

    it "release SHA non semver → confronto per ordine di comparsa (fallback timestamp)" do
      older = "aaaaaaa"
      newer = "bbbbbbb"
      create(:release, project:, version: older, first_event_at: Time.utc(2026, 5, 1))
      create(:release, project:, version: newer, first_event_at: Time.utc(2026, 6, 1))

      expect(described_class.at_or_after?(project:, version: newer, reference: older)).to be(true)
      expect(described_class.at_or_after?(project:, version: older, reference: newer)).to be(false)
    end

    it "SHA senza record release (ordine ignoto) → nil (indeterminato)" do
      expect(described_class.at_or_after?(project:, version: "ccccccc", reference: "ddddddd")).to be_nil
    end
  end

  describe ".live_version" do
    it "ritorna la version della release live in produzione" do
      create(:release, project:, version: "v1.0", environment: "production", current: false)
      create(:release, project:, version: "v1.2", environment: "production", current: true)

      expect(described_class.live_version(project)).to eq("v1.2")
    end

    it "fallback alla più recente release live quando nessuna è in produzione" do
      create(:release, project:, version: "v3.0", environment: "staging", current: true, created_at: 1.day.ago)
      create(:release, project:, version: "v3.1", environment: "qa",      current: true, created_at: 1.hour.ago)

      expect(described_class.live_version(project)).to eq("v3.1")
    end

    it "nil quando il progetto non ha alcuna release live (nessun binding)" do
      create(:release, project:, version: "v1.0", environment: "production", current: false)
      expect(described_class.live_version(project)).to be_nil
    end
  end
end
