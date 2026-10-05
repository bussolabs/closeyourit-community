# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Source, type: :model do
  let(:project) { create(:project) }

  describe "validazioni" do
    it "tool_code unico per progetto" do
      create(:project_source, project:, tool_code: "closeyourit-ruby")
      dup = build(:project_source, project:, tool_code: "closeyourit-ruby")
      expect(dup).not_to be_valid
      expect(build(:project_source, project:, tool_code: "closeyourit-js")).to be_valid
    end

    it "stesso tool_code su progetti diversi è ammesso" do
      create(:project_source, project:, tool_code: "closeyourit-ruby")
      expect(build(:project_source, tool_code: "closeyourit-ruby")).to be_valid
    end

    it "normalizza tool_code (strip)" do
      source = create(:project_source, project:, tool_code: "  closeyourit-ruby  ")
      expect(source.tool_code).to eq("closeyourit-ruby")
    end
  end

  describe ".track!" do
    it "crea la fonte al primo evento con versione, finestra attività e contatore 1" do
      at = Time.utc(2026, 7, 1, 12)
      described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.0", occurred_at: at)

      source = project.sources.find_by!(tool_code: "closeyourit-js")
      expect(source.version).to eq("0.2.0")
      expect(source.events_count).to eq(1)
      expect(source.first_seen_at).to be_within(1).of(at)
      expect(source.last_seen_at).to be_within(1).of(at)
    end

    it "eventi successivi aggiornano la versione (last-write-wins), allargano la finestra e incrementano" do
      early = Time.utc(2026, 7, 1, 10)
      late  = Time.utc(2026, 7, 1, 14)
      described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.0", occurred_at: early)
      described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.1", occurred_at: late)

      source = project.sources.find_by!(tool_code: "closeyourit-js")
      expect(source.version).to eq("0.2.1")
      expect(source.events_count).to eq(2)
      expect(source.first_seen_at).to be_within(1).of(early)
      expect(source.last_seen_at).to be_within(1).of(late)
    end

    it "un evento senza versione non azzera la versione già nota" do
      described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.0", occurred_at: Time.current)
      described_class.track!(project:, tool_code: "closeyourit-js", version: nil, occurred_at: Time.current)

      expect(project.sources.find_by!(tool_code: "closeyourit-js").version).to eq("0.2.0")
    end

    it "tool_code blank → no-op (nessuna fonte creata)" do
      expect do
        described_class.track!(project:, tool_code: "", version: "1.0", occurred_at: Time.current)
        described_class.track!(project:, tool_code: nil, version: "1.0", occurred_at: Time.current)
      end.not_to change(project.sources, :count)
    end

    it "registra anche un tool ignoto (telemetria: si registra ciò che arriva)" do
      described_class.track!(project:, tool_code: "closeyourit-futuro", version: "9.9", occurred_at: Time.current)
      expect(project.sources.find_by(tool_code: "closeyourit-futuro")).to be_present
    end

    it "tool_code placeholder di scrub → no-op (FILTERED/[FILTERED]/[Filtered]/REDACTED)" do
      expect do
        [ "FILTERED", "[FILTERED]", "[Filtered]", "REDACTED" ].each do |code|
          described_class.track!(project:, tool_code: code, version: "1.0", occurred_at: Time.current)
        end
      end.not_to change(project.sources, :count)
    end
  end

  # Cronologia versioni (CYRA-64): oltre all'upsert della fonte, track! storicizza ogni versione vista in
  # projects_source_versions, con la finestra optin (first_seen_at) → optout (last_seen_at).
  describe ".track! — cronologia versioni (CYRA-64)" do
    it "registra la versione vista come riga di cronologia (optin = optout = istante)" do
      at = Time.utc(2026, 7, 1, 12)
      described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.0", occurred_at: at)

      version = project.sources.find_by!(tool_code: "closeyourit-js").versions.sole
      expect(version.version).to eq("0.2.0")
      expect(version.first_seen_at).to be_within(1).of(at)
      expect(version.last_seen_at).to be_within(1).of(at)
    end

    it "eventi ripetuti con la stessa versione allargano la finestra (optin resta, optout avanza)" do
      early = Time.utc(2026, 7, 1, 10)
      late  = Time.utc(2026, 7, 1, 14)
      described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.0", occurred_at: early)
      Ops::LocalGate.clear # the coalesce window has expired between the two events
      described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.0", occurred_at: late)

      version = project.sources.find_by!(tool_code: "closeyourit-js").versions.sole
      expect(version.first_seen_at).to be_within(1).of(early)
      expect(version.last_seen_at).to be_within(1).of(late)
    end

    it "un upgrade dell'SDK apre una riga nuova; la vecchia resta congelata al suo optout" do
      t1 = Time.utc(2026, 7, 1, 10)
      t2 = Time.utc(2026, 7, 1, 12)
      t3 = Time.utc(2026, 7, 2, 9)
      described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.0", occurred_at: t1)
      Ops::LocalGate.clear # the coalesce window has expired between the two events
      described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.0", occurred_at: t2)
      described_class.track!(project:, tool_code: "closeyourit-js", version: "0.3.0", occurred_at: t3)

      source = project.sources.find_by!(tool_code: "closeyourit-js")
      history = source.versions.chronological.to_a
      expect(history.map(&:version)).to eq([ "0.2.0", "0.3.0" ])
      expect(history.first.first_seen_at).to be_within(1).of(t1)
      expect(history.first.last_seen_at).to be_within(1).of(t2) # optout verso la nuova
      expect(history.second.first_seen_at).to be_within(1).of(t3) # optin della nuova
    end

    it "un evento senza versione non crea righe di cronologia" do
      described_class.track!(project:, tool_code: "closeyourit-js", version: nil, occurred_at: Time.current)

      expect(project.sources.find_by!(tool_code: "closeyourit-js").versions).to be_empty
    end

    it "un tool_code placeholder non lascia alcuna cronologia (no-op)" do
      described_class.track!(project:, tool_code: "[FILTERED]", version: "1.0", occurred_at: Time.current)
      expect(Projects::Source::Version.count).to eq(0)
    end

    # Best-effort: la cronologia è osservazionale e NON deve rompere l'ingest né gonfiare la fonte. Se
    # l'upsert cronologia fallisce, track! prosegue senza rilanciare e senza causare un retry.
    it "se l'upsert cronologia fallisce, track! non rilancia e la fonte resta registrata una sola volta" do
      allow(Projects::Source::Version).to receive(:upsert_all).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect do
        described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.0", occurred_at: Time.current)
      end.not_to raise_error

      source = project.sources.find_by!(tool_code: "closeyourit-js")
      expect(source.version).to eq("0.2.0")
      expect(source.events_count).to eq(1)
      expect(source.versions).to be_empty
    end
  end

  # Coalesce sotto burst (CYRA-42): un backend che emette centinaia di eventi/sec con lo stesso SDK non
  # deve ricontendere la riga hot projects_sources ad ogni campione. Il throttle usa la cache atomica
  # (unless_exist), no-op sotto :null_store di test → come gli spec di broadcast/spike, sostituiamo una
  # cache reale (MemoryStore) fresca per ogni esempio, così il throttle è realmente attivo qui.
  describe ".track! — coalesce sotto burst (CYRA-42)" do
    before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

    it "coalesce gli upsert ravvicinati per [progetto, tool, versione]: il secondo evento identico è throttlato" do
      3.times do
        described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.0", occurred_at: Time.current)
      end

      source = project.sources.find_by!(tool_code: "closeyourit-js")
      expect(source.events_count).to eq(1) # un solo upsert nella finestra: gli altri due non contendono la riga
    end

    it "does not write the shared cache again while this process holds the coalesce window" do
      described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.0", occurred_at: Time.current)
      allow(Rails.cache).to receive(:write).and_call_original

      2.times do
        described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.0", occurred_at: Time.current)
      end

      expect(Rails.cache).not_to have_received(:write)
    end

    it "un cambio di versione bypassa il throttle e aggiorna SUBITO (la versione SDK resta aggiornata)" do
      described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.0", occurred_at: Time.current)
      described_class.track!(project:, tool_code: "closeyourit-js", version: "0.3.0", occurred_at: Time.current)

      source = project.sources.find_by!(tool_code: "closeyourit-js")
      expect(source.version).to eq("0.3.0") # chiave di coalesce diversa (include la versione) → passa subito
      expect(source.events_count).to eq(2)
    end

    it "tool diversi non si coalescono a vicenda (chiave per [progetto, tool, versione])" do
      described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.0", occurred_at: Time.current)
      described_class.track!(project:, tool_code: "closeyourit-ruby", version: "0.4.0", occurred_at: Time.current)

      expect(project.sources.pluck(:tool_code)).to contain_exactly("closeyourit-js", "closeyourit-ruby")
    end

    it "scaduta la finestra di coalesce, un evento identico torna a registrare l'attività" do
      described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.0", occurred_at: Time.current)
      Rails.cache.clear # simula la scadenza della finestra di coalesce
      Ops::LocalGate.clear
      described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.0", occurred_at: Time.current)

      expect(project.sources.find_by!(tool_code: "closeyourit-js").events_count).to eq(2)
    end

    it "tool e versione con ':' non collidono nella chiave di coalesce (chiave iniettiva)" do
      described_class.track!(project:, tool_code: "a:b", version: "c", occurred_at: Time.current)
      described_class.track!(project:, tool_code: "a", version: "b:c", occurred_at: Time.current)

      # coppie [tool, versione] distinte → due fonti distinte, nessun upsert saltato per collisione di chiave
      expect(project.sources.pluck(:tool_code)).to contain_exactly("a:b", "a")
    end

    it "se l'upsert fallisce, rilascia la finestra di coalesce (i retry non restano soppressi)" do
      failed_once = false
      allow(described_class).to receive(:upsert_all).and_wrap_original do |original, *args, **kwargs|
        if failed_once
          original.call(*args, **kwargs)
        else
          failed_once = true
          raise ActiveRecord::StatementInvalid, "lock timeout"
        end
      end

      expect do
        described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.0", occurred_at: Time.current)
      end.to raise_error(ActiveRecord::StatementInvalid)

      # la chiave del primo tentativo è stata rilasciata dal rescue → il secondo track! riprova SUBITO
      described_class.track!(project:, tool_code: "closeyourit-js", version: "0.2.0", occurred_at: Time.current)
      expect(project.sources.find_by!(tool_code: "closeyourit-js").events_count).to eq(1)
    end
  end

  # Backfill (CYRA-64): semina la cronologia dalle fonti già presenti al deploy, così le versioni note
  # non risultano assenti fino al prossimo ingest.
  describe ".backfill_version_history!" do
    it "semina una riga di cronologia dalla fonte esistente, con la sua finestra di attività" do
      source = create(:project_source, project:, tool_code: "closeyourit-ruby", version: "0.4.0",
                      first_seen_at: 10.days.ago, last_seen_at: 1.hour.ago)

      described_class.backfill_version_history!

      version = source.versions.sole
      expect(version.version).to eq("0.4.0")
      expect(version.first_seen_at).to be_within(1).of(source.first_seen_at)
      expect(version.last_seen_at).to be_within(1).of(source.last_seen_at)
    end

    it "salta le fonti senza versione (nessuna cronologia da seminare)" do
      source = create(:project_source, project:, tool_code: "closeyourit-js", version: nil)
      described_class.backfill_version_history!
      expect(source.versions).to be_empty
    end

    it "è idempotente: una seconda esecuzione non duplica le righe" do
      source = create(:project_source, project:, tool_code: "closeyourit-ruby", version: "0.4.0")
      described_class.backfill_version_history!

      expect { described_class.backfill_version_history! }.not_to change(Projects::Source::Version, :count)
      expect(source.versions.count).to eq(1)
    end

    it "non sovrascrive una cronologia già registrata per quella versione (ON CONFLICT DO NOTHING)" do
      source = create(:project_source, project:, tool_code: "closeyourit-ruby", version: "0.4.0")
      existing = create(:project_source_version, source:, version: "0.4.0",
                        first_seen_at: 30.days.ago, last_seen_at: 20.days.ago)

      described_class.backfill_version_history!

      expect(source.versions.sole.first_seen_at).to be_within(1).of(existing.first_seen_at)
    end

    it "usa created_at come fallback quando la fonte non ha finestra di attività (vincolo NOT NULL)" do
      source = create(:project_source, project:, tool_code: "closeyourit-ruby", version: "0.4.0",
                      first_seen_at: nil, last_seen_at: nil)

      described_class.backfill_version_history!

      version = source.versions.sole
      expect(version.first_seen_at).to be_within(1).of(source.created_at)
      expect(version.last_seen_at).to be_within(1).of(source.created_at)
    end
  end

  describe ".placeholder_code?" do
    it "riconosce i placeholder degli scrubber SDK (case e parentesi insensibili)" do
      [ "FILTERED", "[FILTERED]", "[Filtered]", "filtered", "REDACTED", "[REDACTED]" ].each do |code|
        expect(described_class.placeholder_code?(code)).to be(true), "#{code} dovrebbe essere un placeholder"
      end
    end

    it "un tool reale (anche ignoto) non è un placeholder" do
      [ "closeyourit-ruby", "closeyourit-js", "closeyourit-futuro" ].each do |code|
        expect(described_class.placeholder_code?(code)).to be(false), "#{code} non è un placeholder"
      end
    end

    it "blank non è un placeholder (è semplicemente assente)" do
      expect(described_class.placeholder_code?("")).to be(false)
      expect(described_class.placeholder_code?(nil)).to be(false)
    end
  end

  describe "#tool" do
    it "ritorna la voce del registry per un tool noto" do
      source = build(:project_source, tool_code: "closeyourit-ruby")
      expect(source.tool.code).to eq("closeyourit-ruby")
      expect(source.tool.known?).to be(true)
    end

    it "fallback generico per un tool ignoto" do
      source = build(:project_source, tool_code: "closeyourit-futuro")
      expect(source.tool.code).to eq("closeyourit-futuro")
      expect(source.tool.known?).to be(false)
    end
  end
end
