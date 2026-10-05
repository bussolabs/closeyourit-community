# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::WorkContextSnapshot, type: :model do
  let(:organization) { create(:organization) }
  let(:ticket) { create(:ticket, organization: organization) }

  it "produce uno snapshot valido" do
    expect(build(:work_context_snapshot, ticket: ticket, organization_id: organization.id)).to be_valid
  end

  describe "immutabilità (audit trail)" do
    it "rifiuta la riscrittura del payload di uno snapshot già scritto" do
      snapshot = create(:work_context_snapshot, ticket: ticket, organization_id: organization.id)

      expect { snapshot.update!(payload: { "references" => [ { "key" => "x" } ], "procedures" => [] }) }
        .to raise_error(ActiveRecord::ReadonlyAttributeError)
    end

    it "rifiuta la riscrittura di digest, versione, timestamp e attore" do
      snapshot = create(:work_context_snapshot, ticket: ticket, organization_id: organization.id)

      expect { snapshot.update!(digest: "altro") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect { snapshot.update!(payload_version: 99) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect { snapshot.update!(generated_at: 1.day.from_now) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect { snapshot.update!(actor_name: "Altri") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    end
  end

  describe "uno per ticket (idempotenza sotto concorrenza)" do
    it "rifiuta un secondo snapshot sullo stesso ticket a livello di DB" do
      create(:work_context_snapshot, ticket: ticket, organization_id: organization.id)

      duplicate = build(:work_context_snapshot, ticket: ticket, organization_id: organization.id)

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "campi versionati" do
    it "rifiuta una versione non positiva" do
      expect(build(:work_context_snapshot, ticket: ticket, organization_id: organization.id, payload_version: 0)).to be_invalid
    end

    it "richiede digest e timestamp di generazione" do
      expect(build(:work_context_snapshot, ticket: ticket, organization_id: organization.id, digest: nil)).to be_invalid
      expect(build(:work_context_snapshot, ticket: ticket, organization_id: organization.id, generated_at: nil)).to be_invalid
    end
  end

  describe "integrità tenant" do
    it "è invalido se l'organization non combacia con quella del ticket" do
      snapshot = build(:work_context_snapshot, ticket: ticket, organization_id: create(:organization).id)

      expect(snapshot).to be_invalid
      expect(snapshot.errors[:organization]).to be_present
    end

    it "accetta uno snapshot senza attore (host storico senza service account)" do
      expect(build(:work_context_snapshot, ticket: ticket, organization_id: organization.id, actor: nil)).to be_valid
    end

    it "è invalido se l'attore non è membro dell'org del ticket" do
      outsider = create(:account)
      create(:membership, account: outsider, organization: create(:organization), role: :member)

      snapshot = build(:work_context_snapshot, ticket: ticket, organization_id: organization.id, actor: outsider)

      expect(snapshot).to be_invalid
      expect(snapshot.errors[:actor]).to be_present
    end
  end

  describe "associazione al ticket" do
    it "viene eliminato insieme al suo ticket" do
      create(:work_context_snapshot, ticket: ticket, organization_id: organization.id)

      expect { ticket.destroy }.to change(described_class, :count).by(-1)
    end
  end

  describe "digest canonico e verificabile" do
    it "è invariante rispetto all'ordine delle chiavi (il jsonb non lo preserva)" do
      ordered = { "references" => [ { "key" => "a", "level" => "project", "position" => 0 } ], "procedures" => [] }
      shuffled = { "procedures" => [], "references" => [ { "position" => 0, "level" => "project", "key" => "a" } ] }

      expect(described_class.compute_digest(ordered)).to eq(described_class.compute_digest(shuffled))
    end

    it "cambia se cambia il contenuto delle istruzioni" do
      base = { "references" => [ { "key" => "a" } ], "procedures" => [] }
      other = { "references" => [ { "key" => "b" } ], "procedures" => [] }

      expect(described_class.compute_digest(base)).not_to eq(described_class.compute_digest(other))
    end

    it "preserva l'ordine degli elementi negli array (significativo, non va ordinato)" do
      one = { "references" => [ { "key" => "a" }, { "key" => "b" } ], "procedures" => [] }
      two = { "references" => [ { "key" => "b" }, { "key" => "a" } ], "procedures" => [] }

      expect(described_class.compute_digest(one)).not_to eq(described_class.compute_digest(two))
    end

    it "digest_matches? resta vero dopo il round-trip in DB" do
      snapshot = create(:work_context_snapshot, ticket: ticket, organization_id: organization.id,
                                                payload: { "references" => [ { "key" => "x", "level" => "organization", "position" => 0 } ],
                                                           "procedures" => [] })

      expect(snapshot.reload.digest_matches?).to be(true)
    end

    it "digest_matches? è falso se il digest salvato non combacia col payload" do
      snapshot = create(:work_context_snapshot, ticket: ticket, organization_id: organization.id)
      # update_all bypassa attr_readonly (SQL diretto): simula una manomissione della riga.
      described_class.where(id: snapshot.id).update_all(digest: "manomesso")

      expect(snapshot.reload.digest_matches?).to be(false)
    end
  end
end
