# frozen_string_literal: true

require "rails_helper"

# Scope del team: team ↔ progetto e team ↔ gruppo-di-progetti. Devono appartenere alla STESSA org
# del team (difesa BOLA: un team non può collegarsi a risorse di un'altra org).
RSpec.describe "Team scope accesses", type: :model do
  describe Connections::TeamProjectAccess do
    it "la factory di default è valida" do
      expect(build(:team_project_access)).to be_valid
    end

    it "unicità (team, project)" do
      access = create(:team_project_access)
      dup = build(:team_project_access, team: access.team, project: access.project)
      expect(dup).not_to be_valid
    end

    it "rifiuta un progetto di un'altra org (BOLA)" do
      team = create(:team)
      other_project = create(:project) # org diversa
      access = build(:team_project_access, team: team, project: other_project)
      expect(access).not_to be_valid
      expect(access.errors[:project]).to be_present
    end

    it "guard tenant: non solleva quando team/project sono assenti" do
      # Esercita il return del guard difensivo blank? in project_belongs_to_team_organization.
      expect { Connections::TeamProjectAccess.new.valid? }.not_to raise_error
    end
  end

  describe Connections::TeamGroupAccess do
    it "la factory di default è valida" do
      expect(build(:team_group_access)).to be_valid
    end

    it "unicità (team, group)" do
      access = create(:team_group_access)
      dup = build(:team_group_access, team: access.team, group: access.group)
      expect(dup).not_to be_valid
    end

    it "rifiuta un gruppo di un'altra org (BOLA)" do
      team = create(:team)
      other_group = create(:group) # org diversa
      access = build(:team_group_access, team: team, group: other_group)
      expect(access).not_to be_valid
      expect(access.errors[:group]).to be_present
    end

    it "guard tenant: non solleva quando team/group sono assenti" do
      # Esercita il return del guard difensivo blank? in group_belongs_to_team_organization.
      expect { Connections::TeamGroupAccess.new.valid? }.not_to raise_error
    end
  end
end
