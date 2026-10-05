# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::Service::Create do
  let(:organization) { create(:organization, slug: "acme") }

  describe "#call" do
    it "crea un service account non-umano membro dell'org" do
      result = described_class.call(organization: organization, name: "Deploy Bot")

      expect(result).to be_ok
      account = result.value
      expect(account).to be_service
      expect(account).not_to be_god
      expect(account.name).to eq("Deploy Bot")
      expect(organization.memberships.find_by(account: account).role).to eq("member")
    end

    it "genera email sintetica non-routable e handle valido" do
      account = described_class.call(organization: organization, name: "Deploy Bot").value

      expect(account.handle).to match(/\A[a-z0-9_]+\z/)
      expect(account.email).to eq("service+#{account.handle}@acme.cyi.local")
    end

    it "concede la visibilità sui progetti selezionati" do
      project = create(:project, organization: organization)
      other = create(:project, organization: organization)

      account = described_class.call(
        organization: organization, name: "Bot", project_ids: [ project.id ]
      ).value

      expect(account.directly_accessible_projects).to include(project)
      expect(account.directly_accessible_projects).not_to include(other)
    end

    it "assegna i ruoli diretti indicati" do
      role = create(:role, organization: organization)

      account = described_class.call(
        organization: organization, name: "Bot", role_ids: [ role.id ]
      ).value

      expect(account.assigned_roles).to include(role)
    end

    context "grant_secrets" do
      it "aggiunge gli override allow secrets.read e secrets.manage" do
        account = described_class.call(
          organization: organization, name: "Bot", grant_secrets: true
        ).value

        overrides = account.account_permissions.where(organization: organization)
        expect(overrides.where(permission_key: "secrets.read", effect: "allow")).to exist
        expect(overrides.where(permission_key: "secrets.manage", effect: "allow")).to exist
      end

      it "senza il flag non concede alcun secret" do
        account = described_class.call(organization: organization, name: "Bot").value

        expect(account.account_permissions.where(permission_key: "secrets.manage")).not_to exist
      end
    end

    it "deduplica l'handle globale con suffisso numerico" do
      first = described_class.call(organization: organization, name: "Bot", handle: "bot").value
      other_org = create(:organization, slug: "beta")
      second = described_class.call(organization: other_org, name: "Bot", handle: "bot").value

      expect(first.handle).to eq("bot")
      expect(second.handle).to eq("bot1")
    end

    context "restrizione environment" do
      it "imposta sulla membership solo i code dichiarati dall'org (scarta gli inesistenti)" do
        create(:environment, organization: organization, code: "staging")
        account = described_class.call(
          organization: organization, name: "Bot", secret_environment_codes: [ "staging", "inesistente" ]
        ).value
        membership = organization.memberships.find_by(account: account)
        expect(membership.secret_environment_codes).to eq([ "staging" ])
      end

      it "senza restrizione la membership resta senza code (accesso a tutti gli env)" do
        account = described_class.call(organization: organization, name: "Bot").value
        membership = organization.memberships.find_by(account: account)
        expect(membership.secret_environment_codes).to eq([])
      end
    end

    # CYRA-237 (review #1): il guard di visibilità sullo scope vale anche coniando un service account —
    # un delegato non-owner non può dargli progetti che lui stesso non vede (altrimenti otterrebbe, via il
    # token del service account, l'accesso — e i secret — di progetti nascosti).
    context "guard di visibilità sullo scope (actor: delegato non-owner)" do
      let(:actor) do
        manager = create(:account)
        create(:membership, account: manager, organization: organization, role: :member)
        manager
      end

      it "un progetto che l'attore NON vede → R403-ACCESS-001, nessuna visibilità concessa" do
        # (il rollback dell'account su step-failure è garantito dalla transazione outer in produzione;
        # con le transactional fixtures quella transazione è una join e il rollback non è osservabile qui,
        # come per gli altri step — verifico il contratto pubblico: err + codice + nessun accesso concesso.)
        hidden = create(:project, organization: organization)
        result = described_class.call(organization: organization, name: "Bot",
                                      project_ids: [ hidden.id ], actor: actor)
        expect(result).to be_err
        expect(result.error.code).to eq("R403-ACCESS-001")
        expect(Connections::ProjectMembership.where(project_id: hidden.id)).to be_empty
      end

      it "un progetto che l'attore vede → ok, service account con quella visibilità" do
        visible = create(:project, organization: organization)
        create(:project_membership, account: actor, project: visible)
        result = described_class.call(organization: organization, name: "Bot",
                                      project_ids: [ visible.id ], actor: actor)
        expect(result).to be_ok
        expect(result.value.directly_accessible_projects).to contain_exactly(visible)
      end
    end

    context "input invalido" do
      it "senza nome ritorna err e non lascia account/membership orfani" do
        expect {
          result = described_class.call(organization: organization, name: "")
          expect(result).to be_err
          expect(result.error.code).to match(/^R422-/)
        }.to not_change(Accounts::Account, :count).and not_change(Connections::Membership, :count)
      end

      it "una collisione a livello DB sull'handle (race) ritorna err pulito, mai 500" do
        allow(Accounts::Account).to receive(:create!)
          .and_raise(ActiveRecord::RecordNotUnique.new("duplicate handle"))

        result = described_class.call(organization: organization, name: "Bot")

        expect(result).to be_err
        expect(result.error.code).to eq("R422-SERVICEACCOUNT-001")
      end
    end
  end
end
