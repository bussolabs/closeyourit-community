# frozen_string_literal: true

FactoryBot.define do
  factory :team_project_access, class: "Connections::TeamProjectAccess" do
    association :team
    project { association(:project, organization: team.organization) }
  end

  factory :team_group_access, class: "Connections::TeamGroupAccess" do
    association :team
    group { association(:group, organization: team.organization) }
  end
end
