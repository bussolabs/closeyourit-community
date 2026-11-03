# frozen_string_literal: true

# CYRA-1167 — when each package version came out, shared by every project: a release date never changes.
class CreateVulnerabilitiesPackageReleases < ActiveRecord::Migration[8.1]
  def change
    create_table :vulnerabilities_package_releases, id: :uuid do |t|
      t.string :ecosystem, null: false
      t.string :name, null: false
      t.string :version, null: false
      t.datetime :released_at, null: false
      t.timestamps
    end

    add_index :vulnerabilities_package_releases, %i[ecosystem name version], unique: true,
              name: "index_vulnerabilities_package_releases_on_coordinates"
    add_index :vulnerabilities_package_releases, :released_at
  end
end
