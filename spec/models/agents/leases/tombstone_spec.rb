# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Leases::Tombstone, type: :model do
  describe ".record!" do
    it "registra una sola volta la chiave idempotente del lease" do
      lease = create(:agent_lease)
      released_at = Time.zone.parse("2026-07-13 15:00:00")

      first = described_class.record!(lease:, released_at:)
      second = described_class.record!(lease:, released_at: released_at + 1.minute)

      expect(second.id).to eq(first.id)
      expect(second.reload).to have_attributes(
        organization: lease.organization,
        ticket: lease.ticket,
        host: lease.host,
        run_id: lease.run_id,
        released_at:
      )
    end

    it "delega al DB l'unicità per ticket, host e run" do
      existing = create(:agent_lease)
      described_class.record!(lease: existing, released_at: Time.current)
      duplicate = described_class.new(
        organization: existing.organization,
        ticket: existing.ticket,
        host: existing.host,
        run_id: existing.run_id,
        released_at: Time.current
      )

      expect(described_class.validators_on(:run_id))
        .not_to include(an_instance_of(ActiveRecord::Validations::UniquenessValidator))
      expect(duplicate).to be_valid
      expect { duplicate.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "rifiuta host o ticket di un'altra organization" do
      tombstone = described_class.new(
        organization: create(:organization),
        ticket: create(:ticket, organization: create(:organization)),
        host: create(:agent_host),
        run_id: "run-tenant",
        released_at: Time.current
      )

      expect(tombstone).to be_invalid
      expect(tombstone.errors[:host]).to be_present
      expect(tombstone.errors[:ticket]).to be_present
    end

    # Da CYRA-293 il titolare è polimorfo anche sul tombstone: l'assenza di host non è più un errore
    # su :host (il belongs_to è optional) ma sull'invariante "esattamente un titolare", su :base.
    it "lascia ai belongs_to i riferimenti assenti anche durante la validazione tenant" do
      attributes = { run_id: "run-missing", released_at: Time.current }
      missing_scope = described_class.new(**attributes, organization: nil, host: nil, ticket: nil)
      missing_relations = described_class.new(
        **attributes, organization: create(:organization), host: nil, ticket: nil
      )

      expect(missing_scope).to be_invalid
      expect(missing_relations).to be_invalid
      expect(missing_relations.errors.attribute_names).to include(:ticket, :base)
    end
  end
end
