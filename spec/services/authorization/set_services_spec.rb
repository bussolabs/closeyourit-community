# frozen_string_literal: true

require "rails_helper"

# Servizi idempotenti di assegnazione (stile Connections::SetMemberAccess): reconcile + BOLA +
# audit sync in transazione. Result pattern.
RSpec.describe "RBAC set services" do
  let(:org) { create(:organization) }
  # L'attore è OWNER (unscoped): il guard anti-escalation (CYRA-156) lo bypassa, così questi test sul
  # RECONCILE/idempotenza restano verdi. Il "manager canonico nei test è owner". La regola "non puoi
  # concedere ciò che non possiedi" per attori NON-owner è coperta da grant_guard_spec.rb.
  let(:actor) do
    create(:account).tap { |a| create(:membership, account: a, organization: org, role: :owner) }
  end

  describe Teams::SetTeamScope do
    let(:team) { create(:team, organization: org) }

    it "assegna progetti e gruppi, idempotente, con audit" do
      p1 = create(:project, organization: org)
      g1 = create(:group, organization: org)

      result = described_class.call(team: team, group_ids: [ g1.id ], project_ids: [ p1.id ], actor: actor)
      expect(result).to be_ok
      expect(team.reload.scoped_projects).to contain_exactly(p1)
      expect(team.scoped_groups).to contain_exactly(g1)

      # Idempotente: ri-eseguire non duplica.
      expect { described_class.call(team: team, group_ids: [ g1.id ], project_ids: [ p1.id ], actor: actor) }
        .not_to change { team.reload.project_accesses.count }
    end

    it "sostituisce l'insieme (rimuove i non più selezionati)" do
      p1 = create(:project, organization: org)
      p2 = create(:project, organization: org)
      described_class.call(team: team, group_ids: [], project_ids: [ p1.id, p2.id ], actor: actor)
      described_class.call(team: team, group_ids: [], project_ids: [ p2.id ], actor: actor)
      expect(team.reload.scoped_projects).to contain_exactly(p2)
    end

    it "scarta progetti di altre org (BOLA)" do
      other = create(:project) # org diversa
      described_class.call(team: team, group_ids: [], project_ids: [ other.id ], actor: actor)
      expect(team.reload.scoped_projects).to be_empty
    end

    it "emette un evento di audit" do
      p1 = create(:project, organization: org)
      expect { described_class.call(team: team, group_ids: [], project_ids: [ p1.id ], actor: actor) }
        .to change(Authorization::Event, :count).by_at_least(1)
    end

    it "Result.err R422-ACCESS-002 se una create! solleva RecordInvalid (rescue difensiva)" do
      p1 = create(:project, organization: org)
      allow(team).to receive(:project_accesses).and_raise(ActiveRecord::RecordInvalid.new(team))
      result = described_class.call(team: team, group_ids: [], project_ids: [ p1.id ], actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-ACCESS-002")
    end
  end

  describe Teams::SetTeamRoles do
    let(:team) { create(:team, organization: org) }

    it "assegna ruoli, idempotente, scarta ruoli di altre org" do
      r1 = create(:role, organization: org)
      other = create(:role) # org diversa
      result = described_class.call(team: team, role_ids: [ r1.id, other.id ], actor: actor)
      expect(result).to be_ok
      expect(team.reload.roles).to contain_exactly(r1)
      expect { described_class.call(team: team, role_ids: [ r1.id ], actor: actor) }
        .not_to change { team.reload.team_roles.count }
    end

    it "rimuove i ruoli non più selezionati (reconcile → destroy_all)" do
      r1 = create(:role, organization: org)
      described_class.call(team: team, role_ids: [ r1.id ], actor: actor)
      result = described_class.call(team: team, role_ids: [], actor: actor)
      expect(result).to be_ok
      expect(team.reload.roles).to be_empty
    end

    it "Result.err R422-ACCESS-003 se una create! solleva RecordInvalid (rescue difensiva)" do
      r1 = create(:role, organization: org)
      allow(team).to receive(:team_roles).and_raise(ActiveRecord::RecordInvalid.new(team))
      result = described_class.call(team: team, role_ids: [ r1.id ], actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-ACCESS-003")
    end
  end

  describe Teams::SetTeamMembers do
    let(:team) { create(:team, organization: org) }

    def org_member
      account = create(:account)
      create(:membership, account: account, organization: org)
      account
    end

    it "assegna i membri (solo account dell'org), idempotente" do
      a1 = org_member
      result = described_class.call(team: team, account_ids: [ a1.id ], actor: actor)
      expect(result).to be_ok
      expect(team.reload.members).to contain_exactly(a1)
      expect { described_class.call(team: team, account_ids: [ a1.id ], actor: actor) }
        .not_to change { team.reload.team_memberships.count }
    end

    it "scarta account non membri dell'org (BOLA)" do
      outsider = create(:account) # nessuna membership nell'org
      described_class.call(team: team, account_ids: [ outsider.id ], actor: actor)
      expect(team.reload.members).to be_empty
    end

    it "rimuove i membri non più selezionati (reconcile → destroy_all)" do
      a1 = org_member
      described_class.call(team: team, account_ids: [ a1.id ], actor: actor)
      result = described_class.call(team: team, account_ids: [], actor: actor)
      expect(result).to be_ok
      expect(team.reload.members).to be_empty
    end

    it "Result.err R422-ACCESS-007 se una create! solleva RecordInvalid (rescue difensiva)" do
      a1 = org_member
      allow(team).to receive(:team_memberships).and_raise(ActiveRecord::RecordInvalid.new(team))
      result = described_class.call(team: team, account_ids: [ a1.id ], actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-ACCESS-007")
    end
  end

  describe Authorization::SetRolePermissions do
    let(:role) { create(:role, organization: org) }

    it "imposta le chiavi del ruolo (solo quelle del Catalog), idempotente" do
      result = described_class.call(role: role, permission_keys: [ "tickets.edit", "nope.nope" ], actor: actor)
      expect(result).to be_ok
      expect(role.reload.permission_keys).to contain_exactly("tickets.edit")
      described_class.call(role: role, permission_keys: [ "errors.triage" ], actor: actor)
      expect(role.reload.permission_keys).to contain_exactly("errors.triage")
    end

    it "Result.err R422-ACCESS-004 se una create! solleva RecordInvalid (rescue difensiva)" do
      allow(role).to receive(:role_permissions).and_raise(ActiveRecord::RecordInvalid.new(role))
      result = described_class.call(role: role, permission_keys: [ "tickets.edit" ], actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-ACCESS-004")
    end
  end

  describe Authorization::SetAccountRoles do
    it "assegna ruoli diretti a un account membro, scarta ruoli di altre org" do
      account = create(:account)
      create(:membership, account: account, organization: org)
      r1 = create(:role, organization: org)
      other = create(:role)
      result = described_class.call(organization: org, account: account, role_ids: [ r1.id, other.id ], actor: actor)
      expect(result).to be_ok
      expect(account.reload.assigned_roles.where(organization_id: org.id)).to contain_exactly(r1)
    end
  end

  describe Authorization::SetAccountPermissions do
    it "imposta override allow/deny e rimuove i non più presenti" do
      account = create(:account)
      create(:membership, account: account, organization: org)
      described_class.call(organization: org, account: account,
                           allow_keys: [ "errors.triage" ], deny_keys: [ "tickets.edit" ], actor: actor)
      perms = account.reload.account_permissions.where(organization_id: org.id)
      expect(perms.find_by(permission_key: "errors.triage").effect).to eq("allow")
      expect(perms.find_by(permission_key: "tickets.edit").effect).to eq("deny")

      # Reconcile: ora solo allow su tickets.edit → errors.triage rimosso, tickets.edit diventa allow.
      described_class.call(organization: org, account: account,
                           allow_keys: [ "tickets.edit" ], deny_keys: [], actor: actor)
      perms = account.reload.account_permissions.where(organization_id: org.id)
      expect(perms.pluck(:permission_key)).to contain_exactly("tickets.edit")
      expect(perms.first.effect).to eq("allow")
    end
  end
end
