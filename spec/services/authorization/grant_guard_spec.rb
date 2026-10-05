# frozen_string_literal: true

require "rails_helper"

# CYRA-156 (privilege-escalation): regola STRETTA "non puoi concedere ciò che non possiedi".
# Copre il guard condiviso Authorization::GrantGuard e il suo effetto sui 4 service di assegnazione.
RSpec.describe "Guard anti-escalation dei permessi (CYRA-156)" do
  let(:org) { create(:organization) }

  # Attore non-owner (member dell'org) senza alcun permesso.
  def member(on: org)
    account = create(:account)
    create(:membership, account: account, organization: on, role: :member)
    account
  end

  # Owner dell'org (unscoped → esente dal guard).
  def owner(on: org)
    account = create(:account)
    create(:membership, account: account, organization: on, role: :owner)
    account
  end

  # Concede all'account delle chiavi ORG-LEVEL (via un ruolo diretto): entrano nei suoi org_keys effettivi.
  def grant_org_keys(account, *keys)
    role = create(:role, organization: org)
    keys.each { |k| create(:role_permission, role: role, permission_key: k) }
    create(:account_role, account: account, organization: org, role: role)
  end

  # Concede una chiave SCOPED su un progetto (ruolo + linkage al progetto): l'attore la possiede, ma
  # solo su quel progetto — NON deve poterla concedere org-wide via un bundle.
  def grant_scoped_key(account, key, project)
    role = create(:role, organization: org)
    create(:role_permission, role: role, permission_key: key)
    create(:account_role, account: account, organization: org, role: role)
    create(:project_membership, account: account, project: project)
  end

  # Ruolo bersaglio con delle chiavi.
  def role_with(*keys)
    role = create(:role, organization: org)
    keys.each { |k| create(:role_permission, role: role, permission_key: k) }
    role
  end

  describe Authorization::GrantGuard do
    describe ".forbidden_keys" do
      it "attore nil → nessun vincolo (seed/InstallDefaults senza attore)" do
        expect(described_class.forbidden_keys(actor: nil, organization: org,
                                              keys: %w[tickets.edit members.invite])).to eq([])
      end

      it "keys vuoto → []" do
        expect(described_class.forbidden_keys(actor: member, organization: org, keys: [])).to eq([])
      end

      it "owner (unscoped) → nessun vincolo, neppure su chiavi scoped" do
        expect(described_class.forbidden_keys(actor: owner, organization: org,
                                              keys: %w[tickets.edit organization.manage])).to eq([])
      end

      it "god (unscoped) → nessun vincolo" do
        god = create(:account, god: true)
        expect(described_class.forbidden_keys(actor: god, organization: org, keys: %w[tickets.edit])).to eq([])
      end

      it "non-owner: una chiave org-level NON posseduta è vietata" do
        expect(described_class.forbidden_keys(actor: member, organization: org,
                                              keys: %w[members.invite])).to eq(%w[members.invite])
      end

      it "non-owner: una chiave org-level POSSEDUTA non è vietata" do
        actor = member
        grant_org_keys(actor, "members.invite")
        expect(described_class.forbidden_keys(actor: actor, organization: org, keys: %w[members.invite])).to eq([])
      end

      it "non-owner: una chiave SCOPED è SEMPRE vietata, anche se posseduta su un progetto" do
        actor = member
        project = create(:project, organization: org)
        grant_scoped_key(actor, "tickets.edit", project)
        expect(described_class.forbidden_keys(actor: actor, organization: org,
                                              keys: %w[tickets.edit])).to eq(%w[tickets.edit])
      end

      it "ritorna SOLO il sottoinsieme vietato" do
        actor = member
        grant_org_keys(actor, "members.invite")
        forbidden = described_class.forbidden_keys(actor: actor, organization: org,
                                                   keys: %w[members.invite members.manage tickets.edit])
        expect(forbidden).to contain_exactly("members.manage", "tickets.edit")
      end
    end
  end

  describe Authorization::SetRolePermissions do
    let(:role) { create(:role, organization: org) }

    it "non-owner concede una chiave org-level non posseduta → R403, nessuna mutazione" do
      result = described_class.call(role: role, permission_keys: %w[members.invite], actor: member)
      expect(result).to be_err
      expect(result.error.code).to eq("R403-ACCESS-001")
      expect(result.error.status).to eq(:forbidden)
      expect(result.error.details[:forbidden_keys]).to include("members.invite")
      expect(role.reload.permission_keys).to be_empty
    end

    it "non-owner concede una chiave SCOPED (anche se posseduta su un progetto) → R403" do
      actor = member
      project = create(:project, organization: org)
      grant_scoped_key(actor, "tickets.edit", project)
      result = described_class.call(role: role, permission_keys: %w[tickets.edit], actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R403-ACCESS-001")
      expect(role.reload.permission_keys).to be_empty
    end

    it "attore che POSSIEDE la chiave org-level → successo" do
      actor = member
      grant_org_keys(actor, "members.invite")
      result = described_class.call(role: role, permission_keys: %w[members.invite], actor: actor)
      expect(result).to be_ok
      expect(role.reload.permission_keys).to contain_exactly("members.invite")
    end

    it "owner → successo anche su una chiave scoped" do
      result = described_class.call(role: role, permission_keys: %w[tickets.edit], actor: owner)
      expect(result).to be_ok
      expect(role.reload.permission_keys).to contain_exactly("tickets.edit")
    end

    it "RIMUOVERE una chiave è sempre lecito, anche per un non-owner" do
      described_class.call(role: role, permission_keys: %w[members.invite], actor: owner)
      result = described_class.call(role: role, permission_keys: [], actor: member)
      expect(result).to be_ok
      expect(role.reload.permission_keys).to be_empty
    end
  end

  describe Authorization::SetAccountPermissions do
    let(:target) do
      account = create(:account)
      create(:membership, account: account, organization: org, role: :member)
      account
    end

    it "non-owner concede (allow) una chiave org-level non posseduta → R403, nessuna mutazione" do
      result = described_class.call(organization: org, account: target, allow_keys: %w[members.invite], actor: member)
      expect(result).to be_err
      expect(result.error.code).to eq("R403-ACCESS-001")
      expect(target.account_permissions.where(organization_id: org.id)).to be_empty
    end

    it "non-owner concede (allow) una chiave SCOPED → R403 anche se posseduta su un progetto" do
      actor = member
      project = create(:project, organization: org)
      grant_scoped_key(actor, "tickets.edit", project)
      result = described_class.call(organization: org, account: target, allow_keys: %w[tickets.edit], actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R403-ACCESS-001")
    end

    it "DENY è sempre lecito (restringe, non concede)" do
      result = described_class.call(organization: org, account: target, deny_keys: %w[members.invite], actor: member)
      expect(result).to be_ok
      expect(target.account_permissions.find_by(permission_key: "members.invite").effect).to eq("deny")
    end

    it "auto-elevazione: l'attore non può darsi un allow su una chiave che non ha → R403" do
      actor = member
      result = described_class.call(organization: org, account: actor, allow_keys: %w[members.invite], actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R403-ACCESS-001")
      expect(actor.account_permissions.where(organization_id: org.id)).to be_empty
    end

    it "attore che POSSIEDE la chiave org-level → successo" do
      actor = member
      grant_org_keys(actor, "members.invite")
      result = described_class.call(organization: org, account: target, allow_keys: %w[members.invite], actor: actor)
      expect(result).to be_ok
      expect(target.account_permissions.find_by(permission_key: "members.invite").effect).to eq("allow")
    end
  end

  describe Authorization::SetAccountRoles do
    let(:target) do
      account = create(:account)
      create(:membership, account: account, organization: org, role: :member)
      account
    end

    it "non-owner assegna un ruolo con una chiave org-level non posseduta → R403, nessuna mutazione" do
      role = role_with("members.invite")
      result = described_class.call(organization: org, account: target, role_ids: [ role.id ], actor: member)
      expect(result).to be_err
      expect(result.error.code).to eq("R403-ACCESS-001")
      expect(target.account_roles.where(organization_id: org.id)).to be_empty
    end

    it "non-owner assegna un ruolo con una chiave SCOPED → R403" do
      role = role_with("tickets.edit")
      result = described_class.call(organization: org, account: target, role_ids: [ role.id ], actor: member)
      expect(result).to be_err
      expect(result.error.code).to eq("R403-ACCESS-001")
    end

    it "un ruolo SENZA chiavi è assegnabile anche da un non-owner" do
      role = create(:role, organization: org)
      result = described_class.call(organization: org, account: target, role_ids: [ role.id ], actor: member)
      expect(result).to be_ok
      expect(target.reload.assigned_roles).to include(role)
    end

    it "auto-elevazione: l'attore non può assegnarsi un ruolo con chiavi che non ha → R403" do
      actor = member
      role = role_with("members.invite")
      result = described_class.call(organization: org, account: actor, role_ids: [ role.id ], actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R403-ACCESS-001")
    end

    it "attore che POSSIEDE le chiavi del ruolo → successo" do
      actor = member
      grant_org_keys(actor, "members.invite")
      role = role_with("members.invite")
      result = described_class.call(organization: org, account: target, role_ids: [ role.id ], actor: actor)
      expect(result).to be_ok
      expect(target.reload.assigned_roles).to include(role)
    end
  end

  describe Teams::SetTeamRoles do
    let(:team) { create(:team, organization: org) }

    it "non-owner assegna al team un ruolo con una chiave org-level non posseduta → R403, nessuna mutazione" do
      role = role_with("members.invite")
      result = described_class.call(team: team, role_ids: [ role.id ], actor: member)
      expect(result).to be_err
      expect(result.error.code).to eq("R403-ACCESS-001")
      expect(team.reload.roles).to be_empty
    end

    it "non-owner assegna al team un ruolo con una chiave SCOPED → R403" do
      role = role_with("tickets.edit")
      result = described_class.call(team: team, role_ids: [ role.id ], actor: member)
      expect(result).to be_err
      expect(result.error.code).to eq("R403-ACCESS-001")
    end

    it "attore che POSSIEDE la chiave org-level → successo" do
      actor = member
      grant_org_keys(actor, "members.invite")
      role = role_with("members.invite")
      result = described_class.call(team: team, role_ids: [ role.id ], actor: actor)
      expect(result).to be_ok
      expect(team.reload.roles).to include(role)
    end

    it "owner → successo anche con un ruolo che porta chiavi scoped" do
      role = role_with("tickets.edit")
      result = described_class.call(team: team, role_ids: [ role.id ], actor: owner)
      expect(result).to be_ok
      expect(team.reload.roles).to include(role)
    end
  end
end
