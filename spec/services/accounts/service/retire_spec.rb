# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::Service::Retire do
  let(:org) { create(:organization, slug: "acme") }
  let(:project) { create(:project, organization: org) }

  let(:account) do
    Accounts::Service::Create.call(
      organization: org, name: "Deploy Bot", project_ids: [ project.id ], grant_secrets: true
    ).value
  end

  describe "#call" do
    it "revoca tutti i token del service account" do
      token = Accounts::ApiTokens::Issue.call(account: account, organization: org, name: "ci").value[:token]
      described_class.call(account: account, organization: org)
      expect(token.reload).to be_revoked
    end

    it "rimuove la membership → sparisce dai service account dell'org" do
      account
      expect { described_class.call(account: account, organization: org) }
        .to change { org.accounts.service.count }.by(-1)
    end

    it "azzera l'accesso RBAC (visibilità progetti + override secret)" do
      described_class.call(account: account, organization: org)
      expect(account.reload.directly_accessible_projects.where(organization: org)).to be_empty
      expect(account.account_permissions.where(organization: org)).to be_empty
    end

    it "NON distrugge l'account: la riga sopravvive" do
      described_class.call(account: account, organization: org)
      expect(Accounts::Account.exists?(account.id)).to be(true)
    end

    it "preserva l'audit dei secret: Secrets::Event.actor resta il service account (non nullificato)" do
      event = create(:secret_event, actor: account, organization: org, project: project, action: "read")
      described_class.call(account: account, organization: org)
      expect(event.reload.actor).to eq(account)
    end

    it "ritorna Result.ok con l'account" do
      result = described_class.call(account: account, organization: org)
      expect(result).to be_ok
      expect(result.value).to eq(account)
    end

    it "se uno step di accesso fallisce fa rollback: non rimuove la membership e ritorna err" do
      account # crea l'account PRIMA dello stub (il Create usa SetAccountPermissions per grant_secrets)
      allow(Authorization::SetAccountPermissions).to receive(:call)
        .and_return(Result.err(AppError.new("boom", code: "R422-ACCESS-006")))

      result = described_class.call(account: account, organization: org)

      expect(result).to be_err
      expect(org.memberships.find_by(account: account)).to be_present
    end

    it "sul fallback di validazione mantiene il codice storico R422-SERVICEACCOUNT-002 (contratto CLI)" do
      account
      Accounts::ApiTokens::Issue.call(account: account, organization: org, name: "ci")
      allow(Accounts::ApiTokens::Revoke).to receive(:call)
        .and_raise(ActiveRecord::RecordInvalid.new(Accounts::ApiToken.new))

      result = described_class.call(account: account, organization: org)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-SERVICEACCOUNT-002")
    end
  end
end
