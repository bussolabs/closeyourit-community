# frozen_string_literal: true

# CYRA-872 — quanto è costato un tentativo e con quale modello, dichiarati dall'host alla consegna.
# NULL = costo non noto (Codex, host vecchi): mai uno zero inventato.
class AddCostAndModelToAgentsAttempts < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_attempts, :cost_usd, :decimal, precision: 14, scale: 6
    add_column :agents_attempts, :model, :string
    add_check_constraint :agents_attempts, "cost_usd IS NULL OR cost_usd >= 0", name: "agents_attempts_cost_nonnegative"
  end
end
