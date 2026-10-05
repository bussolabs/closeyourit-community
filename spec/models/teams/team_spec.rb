# frozen_string_literal: true

require "rails_helper"

RSpec.describe Teams::Team, type: :model do
  describe "validazioni" do
    it "richiede il nome" do
      team = build(:team, name: "")
      expect(team).not_to be_valid
      expect(team.errors[:name]).to be_present
    end

    it "nome univoco per organizzazione (collisione)" do
      org = create(:organization)
      create(:team, organization: org, name: "Support")
      dup = build(:team, organization: org, name: "Support")
      expect(dup).not_to be_valid
    end

    it "stesso nome ammesso in org diverse" do
      create(:team, name: "Support")
      other = build(:team, name: "Support") # org diversa (factory)
      expect(other).to be_valid
    end

    it "normalizza il nome (trim)" do
      team = create(:team, name: "  Support  ")
      expect(team.name).to eq("Support")
    end
  end

  describe "associazioni" do
    it "i membri passano dalle team_membership" do
      team = create(:team)
      account = create(:account)
      create(:membership, account: account, organization: team.organization)
      create(:team_membership, team: team, account: account)
      expect(team.members).to include(account)
    end

    it "la factory di default è valida (FactoryBot.lint)" do
      expect(build(:team)).to be_valid
    end
  end

  describe "default_assignee (assegnatario di default dei ticket)" do
    it "è valido senza default_assignee (colonna nullable)" do
      expect(build(:team, default_assignee: nil)).to be_valid
    end

    it "accetta un default_assignee membro dell'organizzazione" do
      org = create(:organization)
      member = create(:account)
      create(:membership, account: member, organization: org)
      team = build(:team, organization: org, default_assignee: member)
      expect(team).to be_valid
    end

    it "rifiuta un default_assignee non membro dell'organizzazione (anti-BOLA)" do
      org = create(:organization)
      outsider = create(:account)
      team = build(:team, organization: org, default_assignee: outsider)
      expect(team).not_to be_valid
      expect(team.errors[:default_assignee]).to be_present
    end
  end
end
