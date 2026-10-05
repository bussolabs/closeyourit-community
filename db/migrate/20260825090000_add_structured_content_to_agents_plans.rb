# frozen_string_literal: true

class AddStructuredContentToAgentsPlans < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_plans, :contract_version, :integer, null: false, default: 1
    add_column :agents_plans, :content, :jsonb, null: false, default: {}

    add_check_constraint :agents_plans, "contract_version IN (1, 2)",
                         name: "agents_plans_contract_version_supported"
    add_check_constraint :agents_plans, "jsonb_typeof(content) = 'object'",
                         name: "agents_plans_content_object"
  end
end
