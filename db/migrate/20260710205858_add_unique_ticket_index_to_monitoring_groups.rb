# frozen_string_literal: true

# CYRA-47: invariante 1:1 gruppo↔ticket a livello DB. Sostituisce l'indice non-unico su ticket_id con
# un indice unico parziale (WHERE ticket_id IS NOT NULL): due gruppi non possono condividere lo stesso
# ticket, mentre i gruppi non promossi (ticket_id NULL, la maggioranza) restano liberi. Difesa in
# profondità dietro il with_lock nei service Errors::/Metrics::PromoteToTicket.
class AddUniqueTicketIndexToMonitoringGroups < ActiveRecord::Migration[8.1]
  def up
    remove_index :errors_groups, name: "index_errors_groups_on_ticket_id"
    add_index :errors_groups, :ticket_id, unique: true, where: "ticket_id IS NOT NULL",
              name: "index_errors_groups_on_ticket_id"

    remove_index :metrics_groups, name: "index_metrics_groups_on_ticket_id"
    add_index :metrics_groups, :ticket_id, unique: true, where: "ticket_id IS NOT NULL",
              name: "index_metrics_groups_on_ticket_id"
  end

  def down
    remove_index :errors_groups, name: "index_errors_groups_on_ticket_id"
    add_index :errors_groups, :ticket_id, name: "index_errors_groups_on_ticket_id"

    remove_index :metrics_groups, name: "index_metrics_groups_on_ticket_id"
    add_index :metrics_groups, :ticket_id, name: "index_metrics_groups_on_ticket_id"
  end
end
