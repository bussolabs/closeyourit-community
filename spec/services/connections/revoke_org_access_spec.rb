# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::RevokeOrgAccess do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let!(:membership) { create(:membership, account: account, organization: organization, role: :member) }

  def issue_token(org = organization)
    Accounts::ApiTokens::Issue.call(account: account, organization: org, name: "cli").value[:token]
  end

  describe "#call" do
    it "revoca le chiavi CLI attive dell'organizzazione" do
      token = issue_token
      described_class.call(account: account, organization: organization)
      expect(token.reload).to be_revoked
    end

    it "la chiave revocata sparisce dallo scope .active (la CLI non la risolve più)" do
      token = issue_token
      described_class.call(account: account, organization: organization)
      expect(Accounts::ApiToken.active.exists?(token.id)).to be(false)
    end

    it "cancella gli inviti di quella email nell'organizzazione" do
      accepted = create(:invitation, organization: organization, email: account.email, accepted_at: Time.current)
      described_class.call(account: account, organization: organization)
      expect(Connections::Invitation.exists?(accepted.id)).to be(false)
    end

    it "non tocca gli inviti della stessa email in altre organizzazioni" do
      other = create(:invitation, email: account.email)
      described_class.call(account: account, organization: organization)
      expect(Connections::Invitation.exists?(other.id)).to be(true)
    end

    it "azzera l'accesso diretto ai progetti dell'organizzazione" do
      project = create(:project, organization: organization)
      create(:project_membership, account: account, project: project)
      described_class.call(account: account, organization: organization)
      expect(account.reload.directly_accessible_projects.where(organization: organization)).to be_empty
    end

    it "azzera l'accesso ai gruppi dell'organizzazione" do
      group = create(:group, organization: organization)
      create(:group_membership, account: account, group: group)
      described_class.call(account: account, organization: organization)
      expect(account.reload.accessible_groups.where(organization: organization)).to be_empty
    end

    it "azzera i ruoli diretti nell'organizzazione" do
      role = create(:role, organization: organization)
      create(:account_role, account: account, organization: organization, role: role)
      described_class.call(account: account, organization: organization)
      expect(account.account_roles.where(organization_id: organization.id)).to be_empty
    end

    it "azzera gli override personali nell'organizzazione" do
      create(:account_permission, account: account, organization: organization,
                                  permission_key: "tickets.edit", effect: :allow)
      described_class.call(account: account, organization: organization)
      expect(account.account_permissions.where(organization_id: organization.id)).to be_empty
    end

    it "rimuove l'appartenenza ai team dell'organizzazione" do
      team = create(:team, organization: organization)
      create(:team_membership, account: account, team: team)
      described_class.call(account: account, organization: organization)
      expect(account.reload.teams.where(organization: organization)).to be_empty
    end

    it "rimuove le preferenze di notifica della coppia account/organizzazione" do
      create(:alerting_preference, account: account, organization: organization)
      described_class.call(account: account, organization: organization)
      expect(Alerting::Preference.where(account: account, organization: organization)).to be_empty
    end

    it "rimuove le sottoscrizioni ai ticket dell'organizzazione (niente watcher orfano)" do
      ticket = create(:ticket, organization: organization)
      create(:ticket_subscription, account: account, ticket: ticket)
      described_class.call(account: account, organization: organization)
      expect(Ticketing::Subscription.where(account: account, organization: organization)).to be_empty
    end

    it "annulla (:skipped) le notifiche email in sospeso → i job digest non le consegnano" do
      held = create(:alerting_notification, account: account, organization: organization,
                                            via: :email, status: :held)
      queued = create(:alerting_notification, account: account, organization: organization,
                                              via: :email, status: :queued, digest_bucket: :daily)
      described_class.call(account: account, organization: organization)
      expect(held.reload).to be_status_skipped
      expect(queued.reload).to be_status_skipped
    end

    it "NON tocca le notifiche già consegnate (:sent), solo quelle in sospeso" do
      sent = create(:alerting_notification, account: account, organization: organization,
                                            via: :email, status: :sent)
      described_class.call(account: account, organization: organization)
      expect(sent.reload).to be_status_sent
    end

    it "rimuove la membership → l'account esce dall'organizzazione" do
      expect { described_class.call(account: account, organization: organization) }
        .to change { organization.memberships.where(account: account).count }.from(1).to(0)
    end

    it "NON distrugge l'account: la riga sopravvive" do
      described_class.call(account: account, organization: organization)
      expect(Accounts::Account.exists?(account.id)).to be(true)
    end

    it "ritorna Result.ok con l'account" do
      result = described_class.call(account: account, organization: organization)
      expect(result).to be_ok
      expect(result.value).to eq(account)
    end

    it "se uno step di accesso fallisce fa rollback: membership e chiave intatte, ritorna err" do
      token = issue_token
      allow(Authorization::SetAccountPermissions).to receive(:call)
        .and_return(Result.err(AppError.new("boom", code: "R422-ACCESS-006")))

      result = described_class.call(account: account, organization: organization)

      expect(result).to be_err
      expect(organization.memberships.where(account: account)).to exist
      expect(token.reload).not_to be_revoked
    end

    it "isola l'altra organizzazione: chiave e membership restano" do
      other = create(:organization)
      create(:membership, account: account, organization: other, role: :member)
      other_token = issue_token(other)

      described_class.call(account: account, organization: organization)

      expect(other_token.reload).not_to be_revoked
      expect(other.memberships.where(account: account)).to exist
    end

    it "sul fallback RecordInvalid usa R422-MEMBER-005 di default" do
      issue_token
      allow(Accounts::ApiTokens::Revoke).to receive(:call)
        .and_raise(ActiveRecord::RecordInvalid.new(Accounts::ApiToken.new))
      result = described_class.call(account: account, organization: organization)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-MEMBER-005")
    end

    it "sul fallback RecordInvalid rispetta invalid_code passato dal chiamante" do
      issue_token
      allow(Accounts::ApiTokens::Revoke).to receive(:call)
        .and_raise(ActiveRecord::RecordInvalid.new(Accounts::ApiToken.new))
      result = described_class.call(account: account, organization: organization,
                                    invalid_code: "R422-SERVICEACCOUNT-002")
      expect(result.error.code).to eq("R422-SERVICEACCOUNT-002")
    end
  end
end
