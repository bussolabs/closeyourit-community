# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::SetMemberAccess do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }

  before { create(:membership, account: account, organization: org, role: :member) }

  def call(group_ids: [], project_ids: [])
    described_class.call(organization: org, account: account, group_ids: group_ids, project_ids: project_ids)
  end

  it "assegna i gruppi selezionati (Result.ok)" do
    g1 = create(:group, organization: org)
    g2 = create(:group, organization: org)
    result = call(group_ids: [ g1.id, g2.id ])
    expect(result).to be_ok
    expect(account.accessible_groups).to contain_exactly(g1, g2)
  end

  it "sostituisce l'insieme (idempotente): rimuove i non più selezionati" do
    g1 = create(:group, organization: org)
    g2 = create(:group, organization: org)
    call(group_ids: [ g1.id, g2.id ])
    call(group_ids: [ g1.id ])
    expect(account.reload.accessible_groups).to contain_exactly(g1)
  end

  it "assegna i progetti selezionati" do
    p1 = create(:project, organization: org)
    result = call(project_ids: [ p1.id ])
    expect(result).to be_ok
    expect(account.directly_accessible_projects).to contain_exactly(p1)
  end

  it "scarta gruppi/progetti di un'altra org (anti-BOLA)" do
    foreign_group = create(:group, organization: create(:organization))
    foreign_project = create(:project, organization: create(:organization))
    call(group_ids: [ foreign_group.id ], project_ids: [ foreign_project.id ])
    expect(account.accessible_groups).to be_empty
    expect(account.directly_accessible_projects).to be_empty
  end

  it "Result.err se l'account non è membro dell'org (integrità tenant)" do
    outsider = create(:account)
    group = create(:group, organization: org)
    result = described_class.call(organization: org, account: outsider, group_ids: [ group.id ], project_ids: [])
    expect(result).to be_err
    expect(result.error.code).to eq("R422-ACCESS-001")
  end

  it "non tocca le assegnazioni in un'altra org" do
    other_org = create(:organization)
    create(:membership, account: account, organization: other_org, role: :member)
    other_group = create(:group, organization: other_org)
    create(:group_membership, account: account, group: other_group)

    g1 = create(:group, organization: org)
    call(group_ids: [ g1.id ])

    expect(account.reload.accessible_groups).to contain_exactly(g1, other_group)
  end

  it "Result.err con details nil se l'eccezione RecordInvalid non ha record (safe-nav)" do
    # Esercita i rami else di `e.record&.errors&.to_hash` (record nil → details nil).
    allow(account).to receive(:group_memberships).and_raise(ActiveRecord::RecordInvalid.new)
    result = call(group_ids: [])
    expect(result).to be_err
    expect(result.error.code).to eq("R422-ACCESS-001")
    expect(result.error.details).to be_nil
  end

  # CYRA-237: un attore non-owner non può assegnare (a sé o ad altri) progetti/gruppi che non vede.
  describe "guard di visibilità (actor:)" do
    # Attore che gestisce i membri ma non è owner: vede solo i progetti/gruppi collegati.
    let(:actor) do
      manager = create(:account)
      create(:membership, account: manager, organization: org, role: :member)
      manager
    end

    it "attore non-owner assegna un progetto che NON vede → R403, nessuna mutazione" do
      hidden = create(:project, organization: org)
      result = described_class.call(organization: org, account: account,
                                    group_ids: [], project_ids: [ hidden.id ], actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R403-ACCESS-001")
      expect(result.error.status).to eq(:forbidden)
      expect(account.reload.directly_accessible_projects).to be_empty
    end

    it "attore non-owner assegna un gruppo che NON vede → R403" do
      hidden = create(:group, organization: org)
      result = described_class.call(organization: org, account: account,
                                    group_ids: [ hidden.id ], project_ids: [], actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R403-ACCESS-001")
      expect(account.reload.accessible_groups).to be_empty
    end

    it "attore non-owner assegna un progetto che vede → Result.ok" do
      visible = create(:project, organization: org)
      create(:project_membership, account: actor, project: visible)
      result = described_class.call(organization: org, account: account,
                                    group_ids: [], project_ids: [ visible.id ], actor: actor)
      expect(result).to be_ok
      expect(account.reload.directly_accessible_projects).to contain_exactly(visible)
    end

    it "auto-assegnazione (scenario 1): non posso darmi un progetto che non vedo → R403" do
      hidden = create(:project, organization: org)
      result = described_class.call(organization: org, account: actor,
                                    group_ids: [], project_ids: [ hidden.id ], actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R403-ACCESS-001")
      expect(actor.reload.directly_accessible_projects).to be_empty
    end

    it "owner (unscoped) può assegnare qualunque progetto dell'org" do
      owner = create(:account)
      create(:membership, account: owner, organization: org, role: :owner)
      project = create(:project, organization: org)
      result = described_class.call(organization: org, account: account,
                                    group_ids: [], project_ids: [ project.id ], actor: owner)
      expect(result).to be_ok
      expect(account.reload.directly_accessible_projects).to contain_exactly(project)
    end

    it "senza actor (default nil: seed/preview) → nessun guard, comportamento invariato" do
      project = create(:project, organization: org)
      result = call(project_ids: [ project.id ])
      expect(result).to be_ok
      expect(account.reload.directly_accessible_projects).to contain_exactly(project)
    end

    # Fix #5 (review): sui setter full-replace lo scope preesistente che l'attore non vede resta intatto.
    it "preserva uno scope preesistente fuori-visibilità e aggiunge quello visibile (nessun 403)" do
      hidden = create(:project, organization: org)
      create(:project_membership, account: account, project: hidden) # assegnato prima da un owner
      visible = create(:project, organization: org)
      create(:project_membership, account: actor, project: visible)  # l'attore vede solo 'visible'
      result = described_class.call(organization: org, account: account,
                                    group_ids: [], project_ids: [ visible.id ], actor: actor)
      expect(result).to be_ok
      expect(account.reload.directly_accessible_projects).to contain_exactly(hidden, visible)
    end

    it "riconfermare uno scope preesistente fuori-visibilità non è escalation (nessun 403, resta intatto)" do
      hidden = create(:project, organization: org)
      create(:project_membership, account: account, project: hidden)
      result = described_class.call(organization: org, account: account,
                                    group_ids: [], project_ids: [ hidden.id ], actor: actor)
      expect(result).to be_ok
      expect(account.reload.directly_accessible_projects).to contain_exactly(hidden)
    end
  end
end
