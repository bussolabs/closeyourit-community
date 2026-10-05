# frozen_string_literal: true

require "rails_helper"

# CYRA-367 — sulla pagina più vista comparivano righe come `4500ms SELECT "ticketin…`: SQL grezzo
# tagliato dopo poche parole, spesso su tabelle del framework.
RSpec.describe Metrics::QueryLabel do
  def label(sql) = described_class.new(sql)

  describe "#to_s" do
    it "dice cosa tocca e in che modo" do
      I18n.with_locale(:it) do
        expect(label('SELECT "ticketing_tickets".* FROM "ticketing_tickets" WHERE ?').to_s).to eq("Lettura · ticketing tickets")
        expect(label('INSERT INTO "solid_queue_jobs" ("queue_name") VALUES (?)').to_s).to eq("Scrittura · solid queue jobs")
        expect(label('UPDATE "errors_groups" SET "status" = ?').to_s).to eq("Aggiornamento · errors groups")
        expect(label('DELETE FROM "metrics_samples" WHERE ?').to_s).to eq("Eliminazione · metrics samples")
      end
    end

    it "senza una tabella riconoscibile lascia il titolo com'è, invece di inventarlo" do
      expect(label("VACUUM ANALYZE").to_s).to eq("VACUUM ANALYZE")
      expect(label("").to_s).to eq("")
    end

    it "toglie lo schema dal nome della tabella" do
      expect(label('SELECT * FROM public."ticketing_tickets"').table).to eq("ticketing_tickets")
    end

    it "riconosce la tabella anche in una join" do
      expect(label('SELECT * FROM "a" INNER JOIN "solid_cache_entries" ON ?').table).to eq("a")
    end
  end

  describe "#system?" do
    it "riconosce le tabelle dell'infrastruttura" do
      expect(label('INSERT INTO "solid_queue_jobs" VALUES (?)')).to be_system
      expect(label('SELECT * FROM "solid_cache_entries"')).to be_system
      expect(label('SELECT * FROM "solid_cable_messages"')).to be_system
      expect(label('SELECT * FROM "schema_migrations"')).to be_system
      expect(label('SELECT * FROM "active_storage_blobs"')).to be_system
    end

    it "non tocca le tabelle del prodotto" do
      expect(label('SELECT * FROM "ticketing_tickets"')).not_to be_system
      expect(label("VACUUM ANALYZE")).not_to be_system
    end
  end
end
