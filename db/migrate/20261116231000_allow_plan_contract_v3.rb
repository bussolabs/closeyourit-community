class AllowPlanContractV3 < ActiveRecord::Migration[8.1]
  # CYRA-1319 — a v3 plan proves the ticket's acceptance items instead of keeping its own list.
  def up
    remove_check_constraint :agents_plans, name: "agents_plans_contract_version_supported"
    add_check_constraint :agents_plans, "contract_version = ANY (ARRAY[1, 2, 3])", name: "agents_plans_contract_version_supported"
  end

  def down
    remove_check_constraint :agents_plans, name: "agents_plans_contract_version_supported"
    add_check_constraint :agents_plans, "contract_version = ANY (ARRAY[1, 2])", name: "agents_plans_contract_version_supported"
  end
end
