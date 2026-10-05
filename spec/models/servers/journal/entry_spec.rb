# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::Journal::Entry, type: :model do
  describe "table" do
    it "usa il prefisso nested servers_journal_" do
      expect(described_class.table_name).to eq("servers_journal_entries")
    end
  end

  describe "validazioni" do
    it "è valido con host, organization, occurred_at, priority, message, cursor" do
      expect(build(:server_journal_entry)).to be_valid
    end

    it "richiede occurred_at" do
      expect(build(:server_journal_entry, occurred_at: nil)).not_to be_valid
    end

    it "richiede priority" do
      expect(build(:server_journal_entry, priority: nil)).not_to be_valid
    end

    it "richiede message" do
      expect(build(:server_journal_entry, message: nil)).not_to be_valid
    end

    it "richiede cursor" do
      expect(build(:server_journal_entry, cursor: nil)).not_to be_valid
    end

    it "accetta unit nil (kernel/log senza unit)" do
      expect(build(:server_journal_entry, unit: nil)).to be_valid
    end

    it "valida l'unicità del cursor per host" do
      existing = create(:server_journal_entry)
      dup = build(:server_journal_entry, host: existing.host, cursor: existing.cursor)

      expect(dup).not_to be_valid
    end

    it "consente lo stesso cursor su host diversi (cursor è per-host)" do
      existing = create(:server_journal_entry)
      other_host = create(:server_host, organization: existing.organization)

      expect(build(:server_journal_entry, host: other_host, organization: existing.organization,
                                          cursor: existing.cursor)).to be_valid
    end

    it "rifiuta a livello DB un duplicato [host, cursor] (idempotenza retry agent)" do
      existing = create(:server_journal_entry)

      expect {
        described_class.insert_all!([ { host_id: existing.host_id, organization_id: existing.organization_id,
                                       occurred_at: Time.current, priority: 3, message: "x",
                                       cursor: existing.cursor, created_at: Time.current } ])
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe ".recent" do
    it "ordina per occurred_at desc con tie-break su id" do
      host = create(:server_host)
      org = host.organization
      old = create(:server_journal_entry, host: host, organization: org, occurred_at: 2.hours.ago)
      recent = create(:server_journal_entry, host: host, organization: org, occurred_at: 1.minute.ago)

      expect(described_class.recent.to_a).to eq([ recent, old ])
    end
  end

  describe "cancellazione host" do
    it "cancella in cascata le entries (delete_all via FK)" do
      entry = create(:server_journal_entry)

      expect { entry.host.destroy }.to change(described_class, :count).by(-1)
    end
  end
end
