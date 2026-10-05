# frozen_string_literal: true

# A project inside a group that has a color wears the group's color (Projects::Project#take_group_color).
# The rule applies when a project or a group is saved: the projects already there are repainted here.
# Idempotent. Not reversible: the colors the projects had are not kept anywhere.
class BackfillGroupColorOnProjects < ActiveRecord::Migration[8.1]
  def up
    execute(<<~SQL.squish)
      UPDATE projects
      SET color = projects_groups.color
      FROM projects_groups
      WHERE projects.group_id = projects_groups.id
        AND projects_groups.color IS NOT NULL
        AND projects_groups.color <> ''
        AND projects.color IS DISTINCT FROM projects_groups.color
    SQL
  end

  def down; end
end
