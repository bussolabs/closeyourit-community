# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # A ticket's history, newest first, with the full before/after of every edit: what a CLI user
      # reads before rewriting a ticket. Audit material, so gated by tickets.audit.view. CYRA-1309
      class EventsController < Cli::V1::BaseController
        before_action :set_project!

        def index
          return unless require_permission!("tickets.audit.view", scope: @project)

          ticket = find_ticket!(@project, params[:ticket_id])
          events, meta = paginate(ticket.events.reorder(created_at: :desc, id: :desc))
          render_ok(Ticketing::EventSerializer.new(events), meta: meta)
        end
      end
    end
  end
end
