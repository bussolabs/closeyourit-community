# frozen_string_literal: true

# A help desk request becomes a ticket or joins one that exists (CYRA-941). The link sits on the
# request: many requests can point to the same ticket.
class AddTicketToHelpdeskRequests < ActiveRecord::Migration[8.1]
  def change
    add_reference :helpdesk_requests, :ticket, type: :uuid,
                                               foreign_key: { to_table: :ticketing_tickets, on_delete: :nullify }
    change_column_comment :helpdesk_requests, :status,
                          from: "0 received · 1 discarded", to: "0 received · 1 discarded · 2 converted · 3 linked"
  end
end
