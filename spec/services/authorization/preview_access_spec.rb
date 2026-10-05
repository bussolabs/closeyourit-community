# frozen_string_literal: true

require "rails_helper"

# Schema what-if: il preview applica i Set* in transazione e misura col Resolver reale, poi rolla back.
RSpec.describe Authorization::PreviewAccess do
  let(:org) { create(:organization) }

  def role_with(name, *keys)
    role = create(:role, organization: org, name: name)
    keys.each { |k| create(:role_permission, role: role, permission_key: k) }
    role
  end

  def member!(account) = create(:membership, account: account, organization: org, role: :member)

  describe Authorization::PreviewAccess::Member do
    let(:account) { create(:account) }
    let(:p1) { create(:project, organization: org) }

    before { member!(account) }

    it "AGGIUNGE una chiave scoped quando i params pendenti danno ruolo + scope" do
      role = role_with("Maint", "tickets.edit")

      diff = described_class.call(
        organization: org, account: account, projects: [ p1 ],
        params: { role_ids: [ role.id ], project_ids: [ p1.id ], group_ids: [], overrides: {} }
      )

      row = diff.rows.first
      expect(row.current_keys).to be_empty
      expect(row.added).to include("tickets.edit")
      expect(diff.any_change?).to be true
    end

    it "NON persiste nulla (rollback: ruoli, scope, audit invariati)" do
      role = role_with("Maint", "tickets.edit")

      expect do
        described_class.call(
          organization: org, account: account, projects: [ p1 ],
          params: { role_ids: [ role.id ], project_ids: [ p1.id ], group_ids: [], overrides: {} }
        )
      end.to change(Authorization::AccountRole, :count).by(0)
        .and change(Connections::ProjectMembership, :count).by(0)
        .and change(Authorization::Event, :count).by(0)
    end

    it "un override deny pendente TOGLIE una chiave concessa dal ruolo" do
      role = role_with("Maint", "tickets.edit")
      create(:account_role, account: account, organization: org, role: role)
      create(:project_membership, account: account, project: p1)

      diff = described_class.call(
        organization: org, account: account, projects: [ p1 ],
        params: { role_ids: [ role.id ], project_ids: [ p1.id ], group_ids: [],
                  overrides: { "tickets.edit" => "deny" } }
      )

      row = diff.rows.first
      expect(row.current_keys).to include("tickets.edit")
      expect(row.removed).to include("tickets.edit")
    end

    it "coi params correnti non mostra alcuna modifica (pending == current)" do
      role = role_with("Maint", "tickets.edit")
      create(:account_role, account: account, organization: org, role: role)
      create(:project_membership, account: account, project: p1)

      diff = described_class.call(
        organization: org, account: account, projects: [ p1 ],
        params: { role_ids: [ role.id ], project_ids: [ p1.id ], group_ids: [], overrides: {} }
      )

      expect(diff.any_change?).to be false
      expect(diff.rows.first.current_keys).to include("tickets.edit")
    end

    it "espone il diff org-level (nuova chiave org-level pendente)" do
      role = role_with("People", "members.invite")

      diff = described_class.call(
        organization: org, account: account, projects: [],
        params: { role_ids: [ role.id ], project_ids: [], group_ids: [], overrides: {} }
      )

      cell = diff.org_cells.find { |c| c.key == "members.invite" }
      expect(cell.current).to be false
      expect(cell.pending).to be true
    end

    it "un override allow pendente concede una chiave" do
      diff = described_class.call(
        organization: org, account: account, projects: [],
        params: { role_ids: [], project_ids: [], group_ids: [],
                  overrides: { "members.invite" => "allow" } }
      )

      expect(diff.org_cells.find { |c| c.key == "members.invite" }.pending).to be true
    end

    it "gestisce params senza chiave overrides (nil-safe)" do
      expect do
        described_class.call(
          organization: org, account: account, projects: [],
          params: { role_ids: [], project_ids: [], group_ids: [] }
        )
      end.not_to raise_error
    end
  end

  describe Authorization::PreviewAccess::Team do
    let(:team) { create(:team, organization: org) }
    let(:p1) { create(:project, organization: org) }
    let(:alice) { create(:account) }

    before do
      member!(alice)
      create(:team_membership, account: alice, team: team)
    end

    it "mostra la chiave che il ruolo+scope pendenti del team darebbero al membro" do
      role = role_with("Maint", "tickets.edit")

      diffs = described_class.call(
        team: team, projects: [ p1 ],
        params: { member_ids: [ alice.id ], role_ids: [ role.id ], project_ids: [ p1.id ], group_ids: [] }
      )

      d = diffs.find { |x| x.subject == alice }
      expect(d.membership_change).to be_nil
      expect(d.rows.first.added).to include("tickets.edit")
    end

    it "segnala :added un membro nuovo e :removed uno tolto" do
      bob = create(:account); member!(bob)
      # pending: rimuove alice, aggiunge bob
      diffs = described_class.call(
        team: team, projects: [ p1 ],
        params: { member_ids: [ bob.id ], role_ids: [], project_ids: [], group_ids: [] }
      )

      expect(diffs.find { |x| x.subject == bob }.membership_change).to eq(:added)
      expect(diffs.find { |x| x.subject == alice }.membership_change).to eq(:removed)
    end

    it "NON persiste nulla (rollback: ruoli/scope/membri del team invariati)" do
      role = role_with("Maint", "tickets.edit")

      expect do
        described_class.call(
          team: team, projects: [ p1 ],
          params: { member_ids: [ alice.id ], role_ids: [ role.id ], project_ids: [ p1.id ], group_ids: [] }
        )
      end.to change(Authorization::TeamRole, :count).by(0)
        .and change(Connections::TeamProjectAccess, :count).by(0)
        .and change(Connections::TeamMembership, :count).by(0)
    end
  end
end
