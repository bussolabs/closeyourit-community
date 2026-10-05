class AddTicketQueueEnabledToAgentsAgents < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_agents, :ticket_queue_enabled, :boolean, default: false, null: false
    add_check_constraint :agents_agents,
                         "NOT ticket_queue_enabled OR kind IN (0, 2)",
                         name: "agents_agents_ticket_queue_runtime"
  end
end
