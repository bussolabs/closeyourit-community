class AddRoadmapEnabledToProjectsAndGroups < ActiveRecord::Migration[8.1]
  def up
    add_column :projects, :roadmap_enabled, :boolean, default: false, null: false
    add_column :projects_groups, :roadmap_enabled, :boolean, default: false, null: false

    # Backfill: i progetti con roadmap GIÀ esistente (milestone o ticket feature/improvement, kind
    # 1/2) partono attivi — l'esistente continua a funzionare e i ticket feature/improvement legacy
    # non diventano invalidi. I gruppi restano false (si abilitano a mano). SQL raw: niente dipendenza
    # dai model durante la migration.
    say_with_time "backfill projects.roadmap_enabled" do
      execute(<<~SQL.squish)
        UPDATE projects SET roadmap_enabled = TRUE
        WHERE id IN (SELECT DISTINCT project_id FROM projects_milestones)
           OR id IN (SELECT DISTINCT project_id FROM ticketing_tickets WHERE kind IN (1, 2))
      SQL
    end
  end

  def down
    remove_column :projects_groups, :roadmap_enabled
    remove_column :projects, :roadmap_enabled
  end
end
