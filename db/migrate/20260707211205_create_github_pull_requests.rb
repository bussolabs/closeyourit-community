# frozen_string_literal: true

class CreateGithubPullRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :github_pull_requests, id: :uuid do |t|
      t.timestamps

      t.references :repository, type: :uuid, null: false,
                   foreign_key: { to_table: :github_repositories }
      # Ticket collegato (dal prefisso KEY-N in head_ref/titolo/body, o creato dal ticket). Nullable +
      # nullify alla destroy del ticket.
      t.references :ticket, type: :uuid, null: true,
                   foreign_key: { to_table: :ticketing_tickets }

      t.integer  :number, null: false        # numero PR su GitHub
      t.integer  :state, null: false, default: 0 # enum open/closed/merged
      t.string   :title, null: false
      t.string   :head_ref
      t.string   :base_ref
      t.string   :html_url, null: false
      t.bigint   :github_id                  # id numerico della PR (GitHub)
      t.string   :author_login
      t.datetime :merged_at

      t.index [ :repository_id, :number ], unique: true
    end
  end
end
