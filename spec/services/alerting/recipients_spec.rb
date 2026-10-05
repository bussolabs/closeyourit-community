# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Recipients do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }

  def member_in(role: :member)
    account = create(:account)
    create(:membership, account: account, organization: organization, role: role)
    account
  end

  describe "account di servizio" do
    let!(:owner) { member_in(role: :owner) }

    %i[for for_secrets for_tokens].each do |method|
      it "#{method} esclude un owner di servizio" do
        expect(described_class.public_send(method, project: project)).to contain_exactly(owner)
        owner.update!(kind: :service)
        expect(described_class.public_send(method, project: project)).to be_empty
      end
    end

    %i[for_servers for_agents for_shared_secrets].each do |method|
      it "#{method} esclude un owner di servizio" do
        expect(described_class.public_send(method, organization: organization)).to contain_exactly(owner)
        owner.update!(kind: :service)
        expect(described_class.public_send(method, organization: organization)).to be_empty
      end
    end

    it "esclude il service account con accesso diretto e mantiene l'owner umano" do
      account = create(:account, :service)
      create(:membership, account: account, organization: organization)
      create(:project_membership, account: account, project: project)
      expect(described_class.for(project: project)).to contain_exactly(owner)
    end
  end

  it "include sempre l'owner dell'organizzazione, anche senza assegnazioni" do
    owner = member_in(role: :owner)
    expect(described_class.for(project: project)).to include(owner)
  end

  it "include un account con accesso diretto al progetto" do
    account = member_in
    create(:project_membership, account: account, project: project)
    expect(described_class.for(project: project)).to include(account)
  end

  it "include un account via gruppo del progetto" do
    group = create(:group, organization: organization)
    project.update!(group: group)
    account = member_in
    create(:group_membership, account: account, group: group)
    expect(described_class.for(project: project)).to include(account)
  end

  it "include un account via team con accesso al progetto" do
    account = member_in
    team = create(:team, organization: organization)
    create(:team_membership, account: account, team: team)
    create(:team_project_access, team: team, project: project)
    expect(described_class.for(project: project)).to include(account)
  end

  it "include un account via team con accesso al gruppo" do
    group = create(:group, organization: organization)
    project.update!(group: group)
    account = member_in
    team = create(:team, organization: organization)
    create(:team_membership, account: account, team: team)
    create(:team_group_access, team: team, group: group)
    expect(described_class.for(project: project)).to include(account)
  end

  it "ESCLUDE un membro dell'org senza alcun legame col progetto (confine BOLA)" do
    stranger = member_in
    owner = member_in(role: :owner)
    result = described_class.for(project: project)
    expect(result).to include(owner)
    expect(result).not_to include(stranger)
  end

  it "ESCLUDE un god non membro dell'organizzazione (fuori dal fan-out routine)" do
    god = create(:account, god: true)
    expect(described_class.for(project: project)).not_to include(god)
  end

  # CYRA-241 difesa in profondità: anche se un link scoped sopravvive come residuo alla rimozione
  # dall'org, chi non è più membro non riceve avvisi.
  it "ESCLUDE un account con link al progetto ma non più membro dell'org" do
    account = member_in
    create(:project_membership, account: account, project: project)
    Connections::Membership.where(account: account, organization: organization).delete_all
    expect(described_class.for(project: project)).not_to include(account)
  end

  it "deduplica un account raggiungibile per più strade" do
    account = member_in
    create(:project_membership, account: account, project: project)
    team = create(:team, organization: organization)
    create(:team_membership, account: account, team: team)
    create(:team_project_access, team: team, project: project)
    expect(described_class.for(project: project).to_a.count { |a| a.id == account.id }).to eq(1)
  end
end
