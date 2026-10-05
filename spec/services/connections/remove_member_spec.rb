# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::RemoveMember do
  let(:organization) { create(:organization) }

  it "rimuove un membro" do
    m = create(:membership, organization: organization, role: :member)
    result = described_class.call(membership: m)
    expect(result).to be_ok
    expect(Connections::Membership).not_to exist(m.id)
  end

  it "vieta di rimuovere l'ultimo owner" do
    owner = create(:membership, organization: organization, role: :owner)
    result = described_class.call(membership: owner)
    expect(result).to be_err
    expect(result.error.code).to eq("R422-MEMBER-004")
    expect(Connections::Membership).to exist(owner.id)
  end

  # CYRA-241: rimuovere un membro deve chiudere OGNI accesso residuo, non solo togliere la riga.
  describe "revoca completa dell'accesso (CYRA-241)" do
    let(:account) { create(:account) }
    let!(:membership) { create(:membership, account: account, organization: organization, role: :member) }

    it "Scenario 1: la chiave CLI che aveva smette di funzionare (non più attiva)" do
      token = Accounts::ApiTokens::Issue.call(account: account, organization: organization, name: "cli").value[:token]
      described_class.call(membership: membership)
      expect(Accounts::ApiToken.active.exists?(token.id)).to be(false)
    end

    it "Scenario 2: non compare più tra i destinatari degli avvisi del progetto" do
      project = create(:project, organization: organization)
      create(:project_membership, account: account, project: project)
      described_class.call(membership: membership)
      expect(Alerting::Recipients.for(project: project)).not_to include(account)
    end

    it "reinvito pulito: non resta alcun accesso ereditato (progetti/team/preferenze)" do
      project = create(:project, organization: organization)
      create(:project_membership, account: account, project: project)
      team = create(:team, organization: organization)
      create(:team_membership, account: account, team: team)
      create(:alerting_preference, account: account, organization: organization)

      described_class.call(membership: membership)

      expect(account.reload.directly_accessible_projects.where(organization: organization)).to be_empty
      expect(account.teams.where(organization: organization)).to be_empty
      expect(Alerting::Preference.where(account: account, organization: organization)).to be_empty
    end

    it "smette di seguire i ticket dell'org → niente notifiche dei ticket dopo l'uscita" do
      ticket = create(:ticket, organization: organization)
      create(:ticket_subscription, account: account, ticket: ticket)
      described_class.call(membership: membership)
      expect(Ticketing::Subscription.where(account: account, organization: organization)).to be_empty
    end
  end
end
