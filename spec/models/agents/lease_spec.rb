# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Lease, type: :model do
  describe "validazioni e vincoli" do
    it "richiede run e scadenza" do
      expect(build(:agent_lease, run_id: "")).to be_invalid
      expect(build(:agent_lease, expires_at: nil)).to be_invalid
    end

    it "non richiede più la stringa agent: un lease host-first è valido con execution_phase + profile_digest" do
      expect(build(:agent_lease, :host_first)).to be_valid
    end

    it "accetta solo un execution_phase noto (o nil per i lease legacy)" do
      expect(build(:agent_lease, :host_first, execution_phase: "nope")).to be_invalid
      expect(build(:agent_lease, execution_phase: nil)).to be_valid
    end

    it "esige un profile_digest di 64 caratteri quando presente (o nil per i legacy)" do
      expect(build(:agent_lease, :host_first, profile_digest: "abc")).to be_invalid
      expect(build(:agent_lease, profile_digest: nil)).to be_valid
    end

    it "resta valido in forma legacy: agent presente, execution_phase/profile_digest nil (dual-stack)" do
      expect(build(:agent_lease, agent: "triage", execution_phase: nil, profile_digest: nil)).to be_valid
    end

    it "rifiuta un lease senza identità di lavoro (né agent né fase+impronta)" do
      expect(build(:agent_lease, agent: nil, execution_phase: nil, profile_digest: nil)).to be_invalid
    end

    it "rifiuta un'identità host-first parziale: fase senza impronta o impronta senza fase" do
      expect(build(:agent_lease, :host_first, profile_digest: nil)).to be_invalid
      expect(build(:agent_lease, agent: nil, execution_phase: nil, profile_digest: "a" * 64)).to be_invalid
    end

    it "accetta un lease con titolare account, senza identità di lavoro agente" do
      lease = build(:agent_lease, :held_by_account)

      expect(lease).to be_valid
      expect(lease).to be_human
    end

    it "rifiuta un lease senza titolare o con due titolari" do
      no_holder = build(:agent_lease, :held_by_account, account: nil)
      two_holders = build(:agent_lease, :held_by_account)
      two_holders.host = create(:agent_host, organization: two_holders.organization)

      expect(no_holder).to be_invalid
      expect(two_holders).to be_invalid
    end

    it "rifiuta un titolare account che non appartiene all'organizzazione del lease" do
      lease = build(:agent_lease, :held_by_account, account: create(:account))

      expect(lease).to be_invalid
      expect(lease.errors.attribute_names).to include(:account)
    end

    it "rifiuta un lease con titolare account che porta un'identità di lavoro agente" do
      expect(build(:agent_lease, :held_by_account, agent: "triage")).to be_invalid
      expect(
        build(:agent_lease, :held_by_account, execution_phase: "triage",
                                              profile_digest: Agents::PhaseProfile.for("triage").digest)
      ).to be_invalid
    end

    # Il vincolo DB dev'essere il gemello della validazione, non una rete più larga: se ammettesse un
    # lease account-owned con fase+impronta, un insert_all o un update_column ce lo farebbe entrare.
    it "il DB rifiuta un lease account-owned con identità di lavoro agente, non solo il modello" do
      lease = create(:agent_lease, :held_by_account)

      expect do
        described_class.where(id: lease.id).update_all(
          execution_phase: "triage", profile_digest: Agents::PhaseProfile.for("triage").digest
        )
      end.to raise_error(ActiveRecord::StatementInvalid, /agents_leases_work_identity/)
    end

    it "delega al DB l'unicità globale del ticket" do
      existing = create(:agent_lease)
      duplicate = build(
        :agent_lease,
        organization: existing.organization,
        ticket: existing.ticket,
        host: existing.host
      )

      expect(described_class.validators_on(:ticket_id))
        .not_to include(an_instance_of(ActiveRecord::Validations::UniquenessValidator))
      expect(duplicate).to be_valid
      expect { duplicate.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "rifiuta host o ticket di un'altra organization" do
      lease = build(:agent_lease)
      lease.host = create(:agent_host)
      expect(lease).to be_invalid
      expect(lease.errors[:host]).to be_present

      lease = build(:agent_lease)
      lease.ticket = create(:ticket)
      expect(lease).to be_invalid
      expect(lease.errors[:ticket]).to be_present
    end

    # Da CYRA-293 il titolare è polimorfo: l'assenza di host NON è più un errore su :host (il belongs_to
    # è optional), ma sull'invariante "esattamente un titolare", che vive su :base.
    it "lascia ai belongs_to i riferimenti assenti anche durante la validazione tenant" do
      missing_scope = build(:agent_lease, organization: nil, host: nil, ticket: nil)
      missing_relations = build(:agent_lease, organization: create(:organization), host: nil, ticket: nil)

      expect(missing_scope).to be_invalid
      expect(missing_relations).to be_invalid
      expect(missing_relations.errors.attribute_names).to include(:ticket, :base)
    end
  end

  describe "invariante di identità a livello DB (check_constraint, gemello della validazione)" do
    it "dichiara il check_constraint agents_leases_work_identity" do
      names = described_class.connection.check_constraints("agents_leases").map(&:name)
      expect(names).to include("agents_leases_work_identity")
    end

    it "il DB rifiuta un'identità host-first parziale anche bypassando le validazioni del modello" do
      lease = create(:agent_lease, :host_first)

      expect { lease.update_column(:profile_digest, nil) }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe "#active_at?" do
    let(:expires_at) { Time.zone.parse("2026-07-13 15:00:00") }
    let(:lease) { build(:agent_lease, expires_at:) }

    it "è attivo un secondo prima della scadenza" do
      expect(lease.active_at?(expires_at - 1.second)).to be(true)
    end

    it "è scaduto all'istante esatto" do
      expect(lease.active_at?(expires_at)).to be(false)
    end

    it "è scaduto un secondo dopo" do
      expect(lease.active_at?(expires_at + 1.second)).to be(false)
    end
  end
end
