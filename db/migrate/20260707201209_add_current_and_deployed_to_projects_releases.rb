# frozen_string_literal: true

class AddCurrentAndDeployedToProjectsReleases < ActiveRecord::Migration[8.1]
  def change
    # Stato "live/deployata" autorevole per environment: oggi assente. Marcato dal binding
    # (deploy CI + regola stabilità + repo agganciato) in Github::Releases::Reconcile.
    add_column :projects_releases, :current, :boolean, null: false, default: false
    add_column :projects_releases, :deployed_at, :datetime
    add_column :projects_releases, :git_tag_url, :string # URL del tag/Release su GitHub (dal webhook)

    # Una sola release "live" per [progetto, environment]: indice parziale unico sul flag current.
    add_index :projects_releases, %i[project_id environment],
              unique: true, where: "current",
              name: "index_projects_releases_live_per_environment"
  end
end
