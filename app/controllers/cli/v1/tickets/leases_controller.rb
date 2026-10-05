# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # Presa in carico a termine come sub-resource singleton: POST prende, PUT prolunga, DELETE
      # rilascia. È lo STESSO lease server-side degli host automator (Agents::Leases::*), con titolare
      # account invece che host: così una persona e un agente si escludono davvero a vicenda, cosa che
      # due meccanismi separati non potrebbero garantire.
      #
      # Gate `tickets.assign`: il claim è un'assegnazione a termine, non serve una chiave nuova.
      class LeasesController < Cli::V1::BaseController
        include TicketLeaseOperations

        # Default pensato per una persona che lavora un ticket nell'arco della giornata. Le automazioni
        # passano un TTL corto e rinnovano, così un processo morto libera il ticket in fretta.
        DEFAULT_TTL_SECONDS = 8.hours.to_i

        before_action :set_project!
        before_action :set_ticket

        def create
          return unless require_permission!("tickets.assign", scope: @project)

          result = ::Agents::Leases::Acquire.call(**operation_arguments(ttl: true, fresh_run: true))
          return render_lease_error(result.error) if result.err?

          outcome = result.value
          # 201 = presa nuova, 200 = ripresa idempotente della propria: il client distingue senza
          # dover confrontare i campi del lease.
          outcome.fresh_acquisition ? render_created(AgentLeaseSerializer.new(outcome.lease)) : render_lease(outcome.lease)
        end

        def update
          return unless require_permission!("tickets.assign", scope: @project)

          result = ::Agents::Leases::Renew.call(**operation_arguments(ttl: true))
          return render_lease_error(result.error) if result.err?

          render_lease(result.value)
        end

        def destroy
          return unless require_permission!("tickets.assign", scope: @project)

          result = ::Agents::Leases::Release.call(**operation_arguments)
          return render_lease_error(result.error) if result.err?

          render_ok({ released: true })
        end

        private

        # Anti-BOLA: ticket dentro @project (già ristretto a visible_projects) → fuori scope = R404.
        def set_ticket
          @ticket = find_ticket!(@project, params[:ticket_id])
        end

        # Il service risolve il ticket dal suo codice canonico e pretende che path e body coincidano:
        # qui il ticket è già risolto e autorizzato, quindi si passa il suo codice su entrambi i lati.
        def operation_arguments(ttl: false, fresh_run: false)
          payload = { ticket: @ticket.code, run_id: run_id(fresh_run:) }
          payload[:ttl_seconds] = ttl_seconds if ttl

          {
            organization: Current.organization,
            holder: ::Agents::Leases::Holder.account(Current.account),
            ticket_reference: @ticket.code,
            params: payload
          }
        end

        # Un'automazione che gestisce più lavorazioni con lo stesso token dichiara il proprio run id e
        # comanda lei. Senza, la presa ne conia uno nuovo (mai riusare un run già rilasciato) mentre
        # rinnovo e rilascio leggono quello del lease realmente detenuto: nessuno stato da ricordare
        # sul client, e un ticket preso dalla pagina si rilascia dalla riga di comando.
        def run_id(fresh_run:)
          return params[:run_id] if params[:run_id].present?

          held_lease_run_id(@ticket, Current.account, active_only: fresh_run) || new_lease_run_id("cli")
        end

        def ttl_seconds
          raw = params[:ttl_seconds]
          return DEFAULT_TTL_SECONDS if raw.blank?

          Integer(raw, exception: false) || raw
        end

        def render_lease(lease)
          render_ok(AgentLeaseSerializer.new(lease))
        end

        def render_lease_error(error)
          render_error(error.code, error.message, status: error.status, details: error.details)
        end
      end
    end
  end
end
