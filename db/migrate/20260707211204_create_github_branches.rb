# frozen_string_literal: true

class CreateGithubBranches < ActiveRecord::Migration[8.1]
  def change
    create_table :github_branches, id: :uuid do |t|
      t.timestamps

      t.references :repository, type: :uuid, null: false,
                   foreign_key: { to_table: :github_repositories }
      # Ticket collegato (dedotto dal prefisso KEY-N nel nome branch, o creato dal ticket). Nullable:
      # un branch può non mappare a nessun ticket; alla destroy del ticket il link si azzera.
      t.references :ticket, type: :uuid, null: true,
                   foreign_key: { to_table: :ticketing_tickets }

      t.string :name, null: false      # es. "DRRA-123-fix-login"
      t.string :html_url

      t.index [ :repository_id, :name ], unique: true
    end
  end
end
