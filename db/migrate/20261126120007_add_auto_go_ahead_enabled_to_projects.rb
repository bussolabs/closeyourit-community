# frozen_string_literal: true

# CYRA-1219 — the project's own switch for the automatic go-ahead: with it on, a team ticket the AI judged
# workable reaches the agents without a click (Ticketing::AutoDecideAgentEligibility). Born off; the
# existing projects are switched by 20261127090100_switch_the_automatic_go_ahead_on_for_supporter_projects.
class AddAutoGoAheadEnabledToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :auto_go_ahead_enabled, :boolean, default: false, null: false
  end
end
