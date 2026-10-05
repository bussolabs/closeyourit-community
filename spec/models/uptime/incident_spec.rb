# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::Incident, type: :model do
  it "factory valida" do
    expect(build(:uptime_incident)).to be_valid
  end

  it "richiede started_at" do
    expect(build(:uptime_incident, started_at: nil)).not_to be_valid
  end

  describe "#ongoing? / #resolved? / #duration_seconds" do
    it "aperto: ongoing, durata dall'inizio a ora" do
      travel_to(Time.utc(2026, 6, 26, 12)) do
        inc = build(:uptime_incident, started_at: 3.minutes.ago, resolved_at: nil)
        expect(inc.ongoing?).to be(true)
        expect(inc.resolved?).to be(false)
        expect(inc.duration_seconds).to eq(180)
      end
    end

    it "risolto: durata started→resolved" do
      inc = build(:uptime_incident, started_at: Time.utc(2026, 6, 26, 12), resolved_at: Time.utc(2026, 6, 26, 12, 6))
      expect(inc.resolved?).to be(true)
      expect(inc.duration_seconds).to eq(360)
    end
  end

  describe ".open" do
    it "include solo gli aperti (resolved_at nil)" do
      m = create(:uptime_monitor)
      open_inc = create(:uptime_incident, monitor: m, resolved_at: nil)
      create(:uptime_incident, :resolved, monitor: m)
      expect(described_class.open).to contain_exactly(open_inc)
    end
  end

  describe "enum phase (prefix) — nessuna collisione con resolved?" do
    it "phase resolved non clobbera resolved? (stato macchina)" do
      inc = build(:uptime_incident, phase: :resolved, resolved_at: nil)
      expect(inc.phase_resolved?).to be(true)
      expect(inc.resolved?).to be(false) # ongoing lato macchina
      expect(inc.ongoing?).to be(true)
    end

    it "narrated? true solo con una phase impostata" do
      expect(build(:uptime_incident, phase: nil).narrated?).to be(false)
      expect(build(:uptime_incident, :narrated).narrated?).to be(true)
    end
  end

  describe ".top_level" do
    it "esclude i figli di un raggruppamento" do
      m = create(:uptime_monitor)
      primary = create(:uptime_incident, monitor: m)
      child = create(:uptime_incident, monitor: m, parent: primary)
      expect(described_class.top_level).to contain_exactly(primary)
      expect(described_class.top_level).not_to include(child)
    end
  end

  describe "validazioni di raggruppamento" do
    it "il parent dev'essere dello stesso monitor" do
      m = create(:uptime_monitor)
      other = create(:uptime_incident) # monitor diverso
      child = build(:uptime_incident, monitor: m, parent: other)
      expect(child).not_to be_valid
      expect(child.errors[:parent]).to be_present
    end

    it "il parent dev'essere top-level (no catene a più livelli)" do
      m = create(:uptime_monitor)
      grandparent = create(:uptime_incident, monitor: m)
      parent = create(:uptime_incident, monitor: m, parent: grandparent)
      grandchild = build(:uptime_incident, monitor: m, parent: parent)
      expect(grandchild).not_to be_valid
      expect(grandchild.errors[:parent]).to be_present
    end
  end

  describe "#grouped? e finestra unione (window_*)" do
    it "senza figli: finestra = self" do
      inc = create(:uptime_incident, started_at: Time.utc(2026, 6, 26, 12), resolved_at: Time.utc(2026, 6, 26, 12, 5))
      expect(inc.grouped?).to be(false)
      expect(inc.window_started_at).to eq(Time.utc(2026, 6, 26, 12))
      expect(inc.window_resolved_at).to eq(Time.utc(2026, 6, 26, 12, 5))
      expect(inc.window_ongoing?).to be(false)
    end

    it "con N figli: inizio = min, fine = max dei resolved" do
      m = create(:uptime_monitor)
      primary = create(:uptime_incident, monitor: m, started_at: Time.utc(2026, 6, 26, 12), resolved_at: Time.utc(2026, 6, 26, 12, 3))
      create(:uptime_incident, monitor: m, parent: primary, started_at: Time.utc(2026, 6, 26, 11), resolved_at: Time.utc(2026, 6, 26, 11, 30))
      create(:uptime_incident, monitor: m, parent: primary, started_at: Time.utc(2026, 6, 26, 13), resolved_at: Time.utc(2026, 6, 26, 13, 10))
      primary.reload
      expect(primary.grouped?).to be(true)
      expect(primary.window_started_at).to eq(Time.utc(2026, 6, 26, 11))
      expect(primary.window_resolved_at).to eq(Time.utc(2026, 6, 26, 13, 10))
    end

    it "una finestra ancora aperta → window_resolved_at nil (ongoing)" do
      m = create(:uptime_monitor)
      primary = create(:uptime_incident, monitor: m, started_at: Time.utc(2026, 6, 26, 12), resolved_at: Time.utc(2026, 6, 26, 12, 3))
      create(:uptime_incident, monitor: m, parent: primary, started_at: Time.utc(2026, 6, 26, 13), resolved_at: nil)
      primary.reload
      expect(primary.window_resolved_at).to be_nil
      expect(primary.window_ongoing?).to be(true)
    end
  end

  describe "#updates" do
    it "distrutti con l'incident e ordinati chronological" do
      inc = create(:uptime_incident)
      u1 = create(:uptime_incident_update, incident: inc, phase: :detected)
      u2 = create(:uptime_incident_update, incident: inc, phase: :monitoring)
      expect(inc.updates.chronological.to_a).to eq([ u1, u2 ])
      expect { inc.destroy }.to change(Uptime::IncidentUpdate, :count).by(-2)
    end
  end
end
