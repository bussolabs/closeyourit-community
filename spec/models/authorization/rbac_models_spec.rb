# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Authorization models", type: :model do
  describe Authorization::Role do
    it "factory valida" do
      expect(build(:role)).to be_valid
    end

    it "richiede il nome" do
      expect(build(:role, name: "")).not_to be_valid
    end

    it "nome univoco per org" do
      org = create(:organization)
      create(:role, organization: org, name: "Maintainer")
      expect(build(:role, organization: org, name: "Maintainer")).not_to be_valid
    end

    it "permission_keys e has_permission? riflettono le chiavi del ruolo" do
      role = create(:role)
      create(:role_permission, role: role, permission_key: "tickets.edit")
      expect(role.permission_keys).to contain_exactly("tickets.edit")
      expect(role.has_permission?("tickets.edit")).to be true
      expect(role.has_permission?("tickets.delete")).to be false
    end
  end

  describe Authorization::RolePermission do
    it "factory valida" do
      expect(build(:role_permission)).to be_valid
    end

    it "rifiuta una chiave fuori dal Catalog" do
      expect(build(:role_permission, permission_key: "tickets.teleport")).not_to be_valid
    end

    it "unicità (role, permission_key)" do
      rp = create(:role_permission, permission_key: "tickets.edit")
      expect(build(:role_permission, role: rp.role, permission_key: "tickets.edit")).not_to be_valid
    end
  end

  describe Authorization::TeamRole do
    it "factory valida" do
      expect(build(:team_role)).to be_valid
    end

    it "unicità (team, role)" do
      tr = create(:team_role)
      expect(build(:team_role, team: tr.team, role: tr.role)).not_to be_valid
    end

    it "rifiuta un ruolo di un'altra org (BOLA)" do
      team = create(:team)
      other_role = create(:role) # org diversa
      expect(build(:team_role, team: team, role: other_role)).not_to be_valid
    end
  end

  describe Authorization::AccountRole do
    it "factory valida" do
      expect(build(:account_role)).to be_valid
    end

    it "unicità (account, role)" do
      ar = create(:account_role)
      expect(build(:account_role, account: ar.account, organization: ar.organization, role: ar.role))
        .not_to be_valid
    end

    it "rifiuta un ruolo di un'org diversa da organization (BOLA)" do
      org = create(:organization)
      account = create(:account)
      create(:membership, account: account, organization: org)
      other_role = create(:role) # org diversa
      expect(build(:account_role, account: account, organization: org, role: other_role)).not_to be_valid
    end

    it "guard tenant: non solleva quando role/account/organization sono assenti" do
      # Esercita il return dei due validator custom (role_matches_organization,
      # account_belongs_to_organization) col guard difensivo blank? → nessun NoMethodError.
      account_role = Authorization::AccountRole.new
      expect { account_role.valid? }.not_to raise_error
    end

    it "rifiuta un account NON membro dell'organizzazione (BOLA)" do
      org = create(:organization)
      role = create(:role, organization: org)
      outsider = create(:account) # nessuna membership nell'org
      account_role = Authorization::AccountRole.new(account: outsider, organization: org, role: role)
      expect(account_role).not_to be_valid
      expect(account_role.errors[:account]).to be_present
    end
  end

  describe Authorization::AccountPermission do
    it "factory valida" do
      expect(build(:account_permission)).to be_valid
    end

    it "effect allow/deny" do
      perm = build(:account_permission, effect: :deny)
      expect(perm.effect).to eq("deny")
      expect(perm.deny?).to be true
    end

    it "rifiuta una chiave fuori dal Catalog" do
      expect(build(:account_permission, permission_key: "nope.nope")).not_to be_valid
    end

    it "unicità (account, organization, permission_key)" do
      ap = create(:account_permission, permission_key: "tickets.edit")
      dup = build(:account_permission, account: ap.account, organization: ap.organization,
                  permission_key: "tickets.edit")
      expect(dup).not_to be_valid
    end

    it "guard tenant: non solleva quando account/organization sono assenti" do
      # Esercita il return del guard difensivo blank? in account_belongs_to_organization.
      permission = Authorization::AccountPermission.new
      expect { permission.valid? }.not_to raise_error
    end

    it "rifiuta un account NON membro dell'organizzazione (BOLA)" do
      org = create(:organization)
      outsider = create(:account) # nessuna membership nell'org
      permission = Authorization::AccountPermission.new(account: outsider, organization: org,
                                                        permission_key: "tickets.edit", effect: :allow)
      expect(permission).not_to be_valid
      expect(permission.errors[:account]).to be_present
    end
  end

  describe Authorization::Event do
    it "factory valida" do
      expect(build(:authorization_event)).to be_valid
    end

    it "rifiuta un'action fuori dalla allow-list" do
      expect(build(:authorization_event, action: "nuked_everything")).not_to be_valid
    end

    it "scope chronological ordina per created_at poi id" do
      org = create(:organization)
      older = create(:authorization_event, organization: org, created_at: 2.days.ago)
      newer = create(:authorization_event, organization: org, created_at: 1.day.ago)
      expect(org.authorization_events.chronological.to_a).to eq([ older, newer ])
    end

    describe "#impersonated?" do
      it "true quando true_actor differisce dall'actor (god che impersona)" do
        actor = create(:account)
        true_actor = create(:account)
        event = build(:authorization_event, actor: actor, true_actor: true_actor)
        expect(event.impersonated?).to be true
      end

      it "false quando true_actor coincide con l'actor (nessuna impersonation)" do
        actor = create(:account)
        event = build(:authorization_event, actor: actor, true_actor: actor)
        expect(event.impersonated?).to be false
      end

      it "false quando true_actor è assente (short-circuit su present?)" do
        event = build(:authorization_event, actor: create(:account), true_actor: nil)
        expect(event.impersonated?).to be false
      end
    end
  end
end
