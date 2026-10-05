# frozen_string_literal: true

class AddTicketToMetricsGroups < ActiveRecord::Migration[8.1]
  # Link al ticket promosso (il ticket sopravvive alla cancellazione del gruppo) — mirror di errors_groups.
  def change
    add_reference :metrics_groups, :ticket, type: :uuid, null: true,
                  foreign_key: { to_table: :ticketing_tickets, on_delete: :nullify }
  end
end
