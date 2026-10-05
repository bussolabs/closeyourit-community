# frozen_string_literal: true

class AddEnvironmentToProjectsReleases < ActiveRecord::Migration[8.1]
  def up
    add_column :projects_releases, :environment, :string

    # Storico: le release finora tracciate non hanno environment → assegna 'production'
    # (assunzione ragionevole; le nuove nascono con l'environment del token/evento).
    execute "UPDATE projects_releases SET environment = 'production' WHERE environment IS NULL"

    change_column_null :projects_releases, :environment, false

    # La chiave d'identità della release diventa [progetto, version, environment]:
    # la stessa version può girare in staging E production come due release distinte.
    remove_index :projects_releases, column: %i[project_id version],
                 name: "index_projects_releases_on_project_id_and_version"
    add_index :projects_releases, %i[project_id version environment],
              unique: true, name: "index_projects_releases_on_project_version_environment"
  end

  def down
    remove_index :projects_releases, column: %i[project_id version environment],
                 name: "index_projects_releases_on_project_version_environment"
    add_index :projects_releases, %i[project_id version],
              unique: true, name: "index_projects_releases_on_project_id_and_version"
    remove_column :projects_releases, :environment
  end
end
