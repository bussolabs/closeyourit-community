# frozen_string_literal: true

require "rails_helper"

# Progetti visibili (linkage) di un account in un'org. Fonte unica per controller e service.
RSpec.describe Authorization::VisibleScope do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }

  def member!(role = :member) = create(:membership, account: account, organization: org, role: role)
  def visible_ids = described_class.new(account: account, organization: org).projects.pluck(:id)

  describe "unscoped (vede tutto)" do
    it "owner vede tutti i progetti dell'org, anche senza alcun link" do
      member!(:owner)
      p1 = create(:project, organization: org)
      p2 = create(:project, organization: org)
      expect(visible_ids).to contain_exactly(p1.id, p2.id)
    end

    it "god vede tutto anche senza membership" do
      account.update!(god: true)
      p1 = create(:project, organization: org)
      expect(visible_ids).to contain_exactly(p1.id)
    end
  end

  describe "scoped (member)" do
    before { member!(:member) }

    it "zero link → nessun progetto (strict)" do
      create(:project, organization: org)
      expect(visible_ids).to be_empty
    end

    it "link personale a un progetto → solo quello" do
      p1 = create(:project, organization: org)
      create(:project, organization: org) # non collegato
      create(:project_membership, account: account, project: p1)
      expect(visible_ids).to contain_exactly(p1.id)
    end

    it "link personale a un gruppo → tutti i progetti del gruppo (anche futuri)" do
      group = create(:group, organization: org)
      p1 = create(:project, organization: org, group: group)
      create(:group_membership, account: account, group: group)
      expect(visible_ids).to contain_exactly(p1.id)
      p2 = create(:project, organization: org, group: group) # aggiunto DOPO
      expect(visible_ids).to contain_exactly(p1.id, p2.id)
    end

    it "link via team a un progetto → solo quello" do
      team = create(:team, organization: org)
      create(:team_membership, account: account, team: team)
      p1 = create(:project, organization: org)
      create(:team_project_access, team: team, project: p1)
      expect(visible_ids).to contain_exactly(p1.id)
    end

    it "link via team a un gruppo → progetti del gruppo (presenti e futuri)" do
      team = create(:team, organization: org)
      create(:team_membership, account: account, team: team)
      group = create(:group, organization: org)
      p1 = create(:project, organization: org, group: group)
      create(:team_group_access, team: team, group: group)
      expect(visible_ids).to contain_exactly(p1.id)
      p2 = create(:project, organization: org, group: group)
      expect(visible_ids).to contain_exactly(p1.id, p2.id)
    end

    it "unione di link personali e di team senza duplicati" do
      personal = create(:project, organization: org)
      create(:project_membership, account: account, project: personal)
      team = create(:team, organization: org)
      create(:team_membership, account: account, team: team)
      via_team = create(:project, organization: org)
      create(:team_project_access, team: team, project: via_team)
      expect(visible_ids).to contain_exactly(personal.id, via_team.id)
    end
  end
end
