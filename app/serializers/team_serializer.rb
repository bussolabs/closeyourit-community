# frozen_string_literal: true

# Team (persone con scope) per la CLI. Espone gli id di ruoli/scope/membri per i comandi.
class TeamSerializer < ApplicationSerializer
  attributes :id, :name, :color, :created_at

  attribute(:role_ids) { |team| team.roles.pluck(:id) }
  attribute(:group_ids) { |team| team.scoped_groups.pluck(:id) }
  attribute(:project_ids) { |team| team.scoped_projects.pluck(:id) }
  attribute(:member_ids) { |team| team.members.pluck(:id) }
end
