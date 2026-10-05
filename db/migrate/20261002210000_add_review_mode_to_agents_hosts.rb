# frozen_string_literal: true

# Who reviews a machine's work before delivery (CYRA-921): the other engine (cross, the default and
# the behaviour so far) or the same engine in a new session (same), for machines with one engine.
class AddReviewModeToAgentsHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_hosts, :review_mode, :string, null: false, default: "cross"
    add_check_constraint :agents_hosts, "review_mode IN ('cross', 'same')", name: "agents_hosts_review_mode_valid"
  end
end
