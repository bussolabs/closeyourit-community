# frozen_string_literal: true

# The engine that reviews a machine's work is named (CYAU-226): "the other engine" stops meaning anything
# once there are more than two. Every machine keeps the reviewer it had: cross → the other engine, same → its own.
class ReplaceReviewModeWithReviewerOnAgentsHosts < ActiveRecord::Migration[8.1]
  def up
    add_column :agents_hosts, :reviewer, :string
    execute <<~SQL.squish
      UPDATE agents_hosts SET reviewer = CASE
        WHEN review_mode = 'same' THEN work_engine
        WHEN work_engine = 'claude' THEN 'codex'
        ELSE 'claude'
      END
    SQL
    change_column_null :agents_hosts, :reviewer, false
    change_column_default :agents_hosts, :reviewer, from: nil, to: "codex"
    add_check_constraint :agents_hosts, "reviewer IN ('claude', 'codex')", name: "agents_hosts_reviewer_valid"

    remove_check_constraint :agents_hosts, name: "agents_hosts_review_mode_valid"
    remove_column :agents_hosts, :review_mode
  end

  def down
    add_column :agents_hosts, :review_mode, :string, null: false, default: "cross"
    add_check_constraint :agents_hosts, "review_mode IN ('cross', 'same')", name: "agents_hosts_review_mode_valid"
    execute "UPDATE agents_hosts SET review_mode = CASE WHEN reviewer = work_engine THEN 'same' ELSE 'cross' END"

    remove_check_constraint :agents_hosts, name: "agents_hosts_reviewer_valid"
    remove_column :agents_hosts, :reviewer
  end
end
