# frozen_string_literal: true

# CYRA-1055 — GitHub issues become tickets and stay aligned both ways: the issue↔ticket link, the
# per-repository choices, the twin of each synced comment, a GitHub name on every person and the
# GitHub signature of each organization.
class AddIssueSyncToGithub < ActiveRecord::Migration[8.1]
  def change
    create_table :github_issues, id: :uuid do |t|
      t.references :repository, type: :uuid, null: false,
                                foreign_key: { to_table: :github_repositories, on_delete: :cascade }
      t.references :ticket, type: :uuid, null: false, index: { unique: true },
                            foreign_key: { to_table: :ticketing_tickets, on_delete: :cascade }
      t.integer :number, null: false
      t.bigint :github_id
      t.string :node_id
      t.string :html_url, null: false
      t.string :author_login
      t.datetime :github_updated_at,
                 comment: "Clock of the last GitHub state seen, to drop older deliveries. Not updated_at."
      t.jsonb :synced_state, null: false, default: {},
                             comment: "Last state seen on both sides: remote (issue) and local (ticket)."
      t.string :truncated_fields, array: true, null: false, default: [],
                                  comment: "Texts imported cut: never sent back to GitHub."
      t.string :board_item_node_id
      t.string :board_option_id
      t.timestamps
    end
    add_index :github_issues, %i[repository_id number], unique: true
    add_index :github_issues, :node_id
    add_index :github_issues, :board_item_node_id

    add_column :github_repositories, :issue_sync, :integer, null: false, default: 0
    add_column :github_repositories, :board_node_id, :string
    add_column :github_repositories, :board_title, :string
    add_column :github_repositories, :board_status_field_id, :string
    add_column :github_repositories, :board_columns, :jsonb, null: false, default: {}
    add_column :github_repositories, :label_kinds, :jsonb, null: false, default: {}
    add_column :github_repositories, :label_priorities, :jsonb, null: false, default: {}
    add_column :github_repositories, :issues_reconciled_at, :datetime
    add_index :github_repositories, :board_node_id
    add_check_constraint :github_repositories, "issue_sync = ANY (ARRAY[0, 1, 2])",
                         name: "github_repositories_issue_sync_known"

    add_column :ticketing_comments, :github_comment_id, :bigint
    add_column :ticketing_comments, :github_author_login, :string
    add_column :ticketing_comments, :github_truncated, :boolean, null: false, default: false
    add_index :ticketing_comments, :github_comment_id, unique: true, where: "github_comment_id IS NOT NULL"

    add_column :accounts, :github_login, :string
    add_index :accounts, "lower((github_login)::text)", name: "index_accounts_on_lower_github_login",
                                                         where: "github_login IS NOT NULL"

    add_reference :github_installations, :system_account, type: :uuid,
                                                          foreign_key: { to_table: :accounts, on_delete: :nullify }
  end
end
