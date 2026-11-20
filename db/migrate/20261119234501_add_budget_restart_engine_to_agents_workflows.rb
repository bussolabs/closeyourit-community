# frozen_string_literal: true

# CYRA-1327 — the engine this piece of work restarted from scratch with, once its attempts ran out.
#
# It carries two facts in one column, and that is the point: written means "this run is the second
# attempt at the ticket", and the value says which engine it was handed to. The count cannot live on
# the old run, because restarting from scratch destroys it (Agents::Workflows::Restart, CYRA-1070) —
# a counter there would be destroyed with it and every run would look like the first.
#
# No check constraint on the value: the engine names live in Agents::Council::ENGINES and the twin
# columns that already hold one (`agents_attempts.runtime`, `agents_hosts.work_engine`) are guarded in
# Ruby too. A list in the database would have to be migrated every time that constant grows.
class AddBudgetRestartEngineToAgentsWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_workflows, :budget_restart_engine, :string
  end
end
