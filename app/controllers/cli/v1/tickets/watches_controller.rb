# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # Watch (sottoscrizione) del ticket via CLI. Singleton: 1 iscrizione/account, il client non conosce
      # l'id. PUT iscrive (idempotente e race-safe via Ticketing::Subscription.ensure_for), DELETE disiscrive
      # (idempotente). Si iscrive chiunque vede il ticket (set_project! → visibilità Fase E, anti-BOLA 404):
      # la partecipazione È il gate, nessuna permission key — specchio di Member::Tickets::WatchesController.
      class WatchesController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_ticket

        def update
          Ticketing::Subscription.ensure_for(ticket: @ticket, account: Current.account, source: :manual)
          render_watch
        end

        def destroy
          @ticket.subscriptions.where(account: Current.account).destroy_all
          render_watch
        end

        private

        def set_ticket
          @ticket = find_ticket!(@project, params[:ticket_id])
        end

        # Stato della sottoscrizione dell'account corrente + contatore watcher (envelope {data}).
        def render_watch
          render_ok({
            ticket_id: @ticket.id,
            watchers_count: @ticket.subscriptions.count,
            watching: @ticket.subscriptions.exists?(account: Current.account)
          })
        end
      end
    end
  end
end
