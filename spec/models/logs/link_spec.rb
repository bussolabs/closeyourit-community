# frozen_string_literal: true

require "rails_helper"

RSpec.describe Logs::Link, type: :model do
  it "è valido collegando un log a un errore dello stesso progetto" do
    expect(build(:log_link)).to be_valid
  end

  it "è valido collegando un log a un ticket dello stesso progetto" do
    ticket = create(:ticket)
    entry = create(:log_entry, project: ticket.project)
    expect(build(:log_link, log_entry: entry, linkable: ticket)).to be_valid
  end

  it "rifiuta un linkable_type non ammesso" do
    entry = create(:log_entry)
    link = build(:log_link, log_entry: entry, linkable: entry.project)
    expect(link).not_to be_valid
    expect(link.errors[:linkable_type]).to be_present
  end

  it "rifiuta un linkable di un altro progetto (tenant-integrity)" do
    entry = create(:log_entry)
    foreign = create(:error_group)
    link = build(:log_link, log_entry: entry, linkable: foreign)
    expect(link).not_to be_valid
    expect(link.errors[:linkable]).to be_present
  end

  it "è unico per (log, linkable)" do
    existing = create(:log_link)
    dup = build(:log_link, log_entry: existing.log_entry, linkable: existing.linkable)
    expect(dup).not_to be_valid
  end

  it "cade quando il log viene eliminato" do
    link = create(:log_link)
    expect { link.log_entry.destroy }.to change(described_class, :count).by(-1)
  end

  it "cade quando l'errore collegato viene eliminato" do
    link = create(:log_link)
    expect { link.linkable.destroy }.to change(described_class, :count).by(-1)
  end

  it "guard tenant: non solleva quando log_entry/linkable sono assenti (return)" do
    # Esercita il return del guard difensivo (log_entry.nil? || linkable.nil?) in linkable_in_same_project.
    expect { described_class.new.valid? }.not_to raise_error
  end
end
