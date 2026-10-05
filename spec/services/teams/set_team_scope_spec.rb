# frozen_string_literal: true

require "rails_helper"

RSpec.describe Teams::SetTeamScope do
  let(:org) { create(:organization) }
  let(:team) { create(:team, organization: org) }

  it "imposta lo scope (gruppi/progetti dell'org) → Result.ok" do
    group = create(:group, organization: org)
    project = create(:project, organization: org)
    result = described_class.call(team: team, group_ids: [ group.id ], project_ids: [ project.id ])
    expect(result).to be_ok
    expect(team.reload.scoped_projects).to contain_exactly(project)
    expect(team.scoped_groups).to contain_exactly(group)
  end

  it "sostituisce l'insieme (idempotente): rimuove i non più selezionati" do
    p1 = create(:project, organization: org)
    p2 = create(:project, organization: org)
    described_class.call(team: team, group_ids: [], project_ids: [ p1.id, p2.id ])
    described_class.call(team: team, group_ids: [], project_ids: [ p1.id ])
    expect(team.reload.scoped_projects).to contain_exactly(p1)
  end

  it "scarta progetti di un'altra org (anti-BOLA)" do
    foreign = create(:project, organization: create(:organization))
    described_class.call(team: team, group_ids: [], project_ids: [ foreign.id ])
    expect(team.reload.scoped_projects).to be_empty
  end

  # CYRA-237: anche via team un attore non-owner non può concedere progetti/gruppi che non vede.
  describe "guard di visibilità (actor:)" do
    # Attore che gestisce i team (permissions.manage) ma non è owner: vede solo lo scope collegato.
    let(:actor) do
      manager = create(:account)
      create(:membership, account: manager, organization: org, role: :member)
      manager
    end

    it "attore non-owner assegna al team un progetto che NON vede → R403, nessuna mutazione" do
      hidden = create(:project, organization: org)
      result = described_class.call(team: team, group_ids: [], project_ids: [ hidden.id ], actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R403-ACCESS-001")
      expect(result.error.status).to eq(:forbidden)
      expect(team.reload.scoped_projects).to be_empty
    end

    it "attore non-owner assegna al team un gruppo che NON vede → R403" do
      hidden = create(:group, organization: org)
      result = described_class.call(team: team, group_ids: [ hidden.id ], project_ids: [], actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R403-ACCESS-001")
      expect(team.reload.scoped_groups).to be_empty
    end

    it "attore non-owner assegna al team un progetto che vede → Result.ok" do
      visible = create(:project, organization: org)
      create(:project_membership, account: actor, project: visible)
      result = described_class.call(team: team, group_ids: [], project_ids: [ visible.id ], actor: actor)
      expect(result).to be_ok
      expect(team.reload.scoped_projects).to contain_exactly(visible)
    end

    it "owner (unscoped) può assegnare qualunque progetto dell'org" do
      owner = create(:account)
      create(:membership, account: owner, organization: org, role: :owner)
      project = create(:project, organization: org)
      result = described_class.call(team: team, group_ids: [], project_ids: [ project.id ], actor: owner)
      expect(result).to be_ok
      expect(team.reload.scoped_projects).to contain_exactly(project)
    end

    it "senza actor (default nil) → nessun guard, comportamento invariato" do
      project = create(:project, organization: org)
      result = described_class.call(team: team, group_ids: [], project_ids: [ project.id ])
      expect(result).to be_ok
      expect(team.reload.scoped_projects).to contain_exactly(project)
    end

    # Fix #5 (review): lo scope preesistente del team che l'attore non vede resta intatto.
    it "preserva lo scope preesistente fuori-visibilità e aggiunge quello visibile (nessun 403)" do
      hidden = create(:project, organization: org)
      create(:team_project_access, team: team, project: hidden) # impostato prima da un owner
      visible = create(:project, organization: org)
      create(:project_membership, account: actor, project: visible)
      result = described_class.call(team: team, group_ids: [], project_ids: [ visible.id ], actor: actor)
      expect(result).to be_ok
      expect(team.reload.scoped_projects).to contain_exactly(hidden, visible)
    end
  end
end
