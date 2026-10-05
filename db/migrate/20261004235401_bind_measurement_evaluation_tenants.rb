class BindMeasurementEvaluationTenants < ActiveRecord::Migration[8.1]
  def change
    add_index :alerting_rules, [ :id, :project_id ], unique: true, name: "measurement_rule_tenant_identity"
    add_foreign_key :alerting_evaluations, :alerting_rules, column: [ :rule_id, :project_id ], primary_key: [ :id, :project_id ], on_delete: :cascade
  end
end
