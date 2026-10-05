# frozen_string_literal: true

require "rails_helper"

RSpec.describe Logs::Entry, type: :model do
  it "richiede event_id, message e occurred_at" do
    entry = build(:log_entry, event_id: nil, message: nil, occurred_at: nil)
    expect(entry).not_to be_valid
    expect(entry.errors[:event_id]).to be_present
    expect(entry.errors[:message]).to be_present
    expect(entry.errors[:occurred_at]).to be_present
  end

  it "rifiuta un message vuoto o composto da soli spazi" do
    expect(build(:log_entry, message: "")).not_to be_valid
    expect(build(:log_entry, message: "   ")).not_to be_valid
  end

  it "ha event_id unico per progetto (idempotenza at-least-once)" do
    existing = create(:log_entry)
    dup = build(:log_entry, project: existing.project, event_id: existing.event_id)
    expect(dup).not_to be_valid
  end

  it "consente lo stesso event_id su progetti diversi" do
    existing = create(:log_entry)
    other = build(:log_entry, project: create(:project), event_id: existing.event_id)
    expect(other).to be_valid
  end

  it "appartiene a un project" do
    expect(create(:log_entry).project).to be_a(Projects::Project)
  end

  it "espone tutti i livelli enum con prefisso" do
    expect(described_class.levels.keys).to eq(%w[debug info warning error fatal])
    expect(create(:log_entry, level: :error)).to be_level_error
  end

  it "è immutabile: la tabella ha solo created_at (nessun updated_at)" do
    expect(described_class.column_names).to include("created_at")
    expect(described_class.column_names).not_to include("updated_at")
  end

  describe ".recent" do
    it "ordina reverse-cronologico per occurred_at" do
      project = create(:project)
      old = create(:log_entry, project: project, occurred_at: 2.hours.ago)
      fresh = create(:log_entry, project: project, occurred_at: 1.minute.ago)
      expect(project.logs_entries.recent.to_a).to eq([ fresh, old ])
    end
  end

  describe "indici" do
    # Il dropdown environment dell'index (Member::Monitoring::LogEntriesController#index) esegue un
    # DISTINCT environment sull'intero stream visibile (potenzialmente decine di milioni di righe):
    # senza indice composito è un seq-scan a ogni render. Con [project_id, environment] è un
    # index-only scan (CYRA-59).
    it "ha l'indice composito [project_id, environment] per il DISTINCT environment dell'index" do
      expect(
        ActiveRecord::Base.connection.index_exists?(:logs_entries, %i[project_id environment])
      ).to be(true)
    end
  end
end
