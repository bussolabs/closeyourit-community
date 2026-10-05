# frozen_string_literal: true

require "rails_helper"

# Rami secondari (guard, rimozioni, errori) per completare la copertura del dominio RBAC.
RSpec.describe "RBAC edge cases" do
  let(:org) { create(:organization) }
  # Attore OWNER (unscoped): bypassa il guard anti-escalation (CYRA-156) così i rami di rimozione/errore
  # qui testati non vengono intercettati dal guard. Il caso non-owner è in grant_guard_spec.rb.
  let(:actor) do
    create(:account).tap { |a| create(:membership, account: a, organization: org, role: :owner) }
  end

  describe Authorization::Catalog do
    it "scoped? è false per una chiave sconosciuta" do
      expect(described_class.scoped?("non.esiste")).to be false
    end
  end

  describe Authorization::VisibleScope do
    it "unscoped? è false con account o org nil" do
      expect(described_class.unscoped?(account: nil, organization: org)).to be false
      expect(described_class.unscoped?(account: create(:account), organization: nil)).to be false
    end

    it "un member senza ruolo owner non è unscoped" do
      account = create(:account)
      create(:membership, account: account, organization: org, role: :member)
      expect(described_class.new(account: account, organization: org).unscoped?).to be false
    end
  end

  describe Authorization::Resolver do
    it "account nil → nega (org-level e scoped)" do
      resolver = described_class.new(account: nil, organization: org)
      expect(resolver.can?("members.manage")).to be false
      expect(resolver.can?("tickets.edit", scope: create(:project, organization: org))).to be false
    end

    it "permesso scoped senza scope → nega" do
      account = create(:account)
      create(:membership, account: account, organization: org)
      expect(described_class.new(account: account, organization: org).can?("tickets.edit")).to be false
    end

    it "decisione negata ha origine :none" do
      account = create(:account)
      create(:membership, account: account, organization: org)
      expect(described_class.new(account: account, organization: org).decide("members.manage").origin).to eq(:none)
    end
  end

  describe "validazioni tenant (rami guard/errore)" do
    it "account_role: account non membro dell'org → invalido" do
      org2 = create(:organization)
      account = create(:account) # nessuna membership in org2
      role = create(:role, organization: org2)
      ar = build(:account_role, organization: org2, account: account, role: role)
      expect(ar).not_to be_valid
      expect(ar.errors[:account]).to be_present
    end

    it "account_permission: account non membro dell'org → invalido" do
      org2 = create(:organization)
      account = create(:account)
      ap = build(:account_permission, organization: org2, account: account, permission_key: "tickets.edit")
      expect(ap).not_to be_valid
    end

    it "team_role: senza ruolo resta gestito dal guard (record invalido per belongs_to)" do
      team = create(:team, organization: org)
      expect(build(:team_role, team: team, role: nil)).not_to be_valid
    end
  end

  describe "servizi — rami di rimozione e di errore" do
    it "SetTeamRoles rimuove i ruoli non più selezionati" do
      team = create(:team, organization: org)
      r1 = create(:role, organization: org)
      Teams::SetTeamRoles.call(team: team, role_ids: [ r1.id ], actor: actor)
      Teams::SetTeamRoles.call(team: team, role_ids: [], actor: actor)
      expect(team.reload.roles).to be_empty
    end

    it "SetRolePermissions rimuove tutte le chiavi" do
      role = create(:role, organization: org)
      Authorization::SetRolePermissions.call(role: role, permission_keys: [ "tickets.edit" ], actor: actor)
      Authorization::SetRolePermissions.call(role: role, permission_keys: [], actor: actor)
      expect(role.reload.permission_keys).to be_empty
    end

    it "SetAccountRoles rimuove i ruoli e fallisce con account non membro" do
      account = create(:account)
      create(:membership, account: account, organization: org)
      r1 = create(:role, organization: org)
      Authorization::SetAccountRoles.call(organization: org, account: account, role_ids: [ r1.id ], actor: actor)
      Authorization::SetAccountRoles.call(organization: org, account: account, role_ids: [], actor: actor)
      expect(account.reload.assigned_roles).to be_empty

      stranger = create(:account) # non membro
      result = Authorization::SetAccountRoles.call(organization: org, account: stranger, role_ids: [ r1.id ], actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-ACCESS-005")
    end

    it "SetAccountPermissions: re-set dello stesso effetto è no-op, account non membro fallisce" do
      account = create(:account)
      create(:membership, account: account, organization: org)
      Authorization::SetAccountPermissions.call(organization: org, account: account, allow_keys: [ "tickets.edit" ], actor: actor)
      Authorization::SetAccountPermissions.call(organization: org, account: account, allow_keys: [ "tickets.edit" ], actor: actor)
      expect(account.reload.account_permissions.find_by(permission_key: "tickets.edit").effect).to eq("allow")

      stranger = create(:account)
      result = Authorization::SetAccountPermissions.call(organization: org, account: stranger, allow_keys: [ "tickets.edit" ], actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-ACCESS-006")
    end
  end

  describe Authorization::BackfillOrganization do
    it "org senza admin → nessun team Administrators" do
      org_no_admin = create(:organization)
      create(:membership, account: create(:account), organization: org_no_admin, role: :member)
      result = described_class.call(organization: org_no_admin)
      expect(result).to be_ok
      expect(org_no_admin.teams.find_by(name: "Administrators")).to be_nil
      # i ruoli default vengono comunque installati
      expect(org_no_admin.roles.pluck(:name)).to include("Administrator")
    end
  end
end
