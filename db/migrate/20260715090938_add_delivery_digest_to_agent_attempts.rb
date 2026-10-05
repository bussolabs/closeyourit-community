class AddDeliveryDigestToAgentAttempts < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_attempts, :delivery_digest, :string
    add_column :agents_attempts, :external_run_id, :string, null: false
  end
end
