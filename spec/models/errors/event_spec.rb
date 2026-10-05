# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Event, type: :model do
  describe "factory" do
    it "produce un evento valido" do
      expect(build(:error_event)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede event_id" do
      expect(build(:error_event, event_id: nil)).not_to be_valid
    end

    it "richiede occurred_at" do
      expect(build(:error_event, occurred_at: nil)).not_to be_valid
    end

    it "event_id unico per progetto (idempotenza)" do
      event = create(:error_event)
      dup = build(:error_event, project: event.project, group: event.group, event_id: event.event_id)
      expect(dup).not_to be_valid
    end

    it "permette lo stesso event_id in progetti diversi" do
      event = create(:error_event)
      other_group = create(:error_group)
      other = build(:error_event, project: other_group.project, group: other_group, event_id: event.event_id)
      expect(other).to be_valid
    end
  end

  describe "associazioni" do
    it "richiede un gruppo" do
      expect(build(:error_event, group: nil, project: create(:project))).not_to be_valid
    end

    it "richiede un progetto" do
      expect(build(:error_event, group: create(:error_group), project: nil)).not_to be_valid
    end
  end

  describe "indici" do
    # new_user_for? (Errors::Ingest::Record) fa un exists? su [group_id, user_hash]: senza questo
    # indice composito è un full-scan del gruppo (milioni di righe) col filtro user_hash sul heap,
    # con questo è una index-only lookup O(log n) sotto burst di ingest (CYRA-50).
    it "ha l'indice composito [group_id, user_hash] per la lookup index-only di new_user_for?" do
      expect(
        ActiveRecord::Base.connection.index_exists?(:errors_events, %i[group_id user_hash])
      ).to be(true)
    end
  end
end
