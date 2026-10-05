# frozen_string_literal: true

module Member
  module Tickets
    # Presa in carico a termine dalla pagina del ticket. È lo STESSO lease server-side che usano gli
    # agent host e la CLI (Agents::Leases::*): un solo titolare per ticket, chiunque esso sia.
    #
    # Semantica soft (CYRA-292): il lease non blocca nessuna scrittura — chi non lo detiene vede
    # l'avviso e può comunque lavorare il ticket. Serve a non fare due volte lo stesso lavoro, non a
    # chiudere fuori una persona da un ticket suo per colpa di un lease orfano.
    class LeasesController < Member::BaseController
      include TicketLeaseOperations

      # Una giornata di lavoro. Le automazioni passano TTL corti e rinnovano; una persona che chiude
      # il browser non deve trovare il ticket ancora occupato il giorno dopo.
      TTL_SECONDS = 8.hours.to_i

      before_action :set_ticket
      before_action -> { require_permission!("tickets.assign", scope: @ticket.project) }

      def create
        result = ::Agents::Leases::Acquire.call(**operation_arguments(ttl: true, fresh_run: true))

        redirect_back fallback_location: member_ticket_path(@ticket),
                      **feedback(result, success: t("member.tickets.lease.taken"))
      end

      def destroy
        result = ::Agents::Leases::Release.call(**operation_arguments)

        redirect_back fallback_location: member_ticket_path(@ticket),
                      **feedback(result, success: t("member.tickets.lease.released"))
      end

      private

      def operation_arguments(ttl: false, fresh_run: false)
        # Il run id non è mai "quello della persona": la presa ne conia uno nuovo, rilascio e rinnovo
        # leggono quello del lease davvero detenuto. Così il pulsante Rilascia funziona anche su un
        # ticket preso dalla riga di comando, e un ticket rilasciato resta riprendibile (un run già
        # rilasciato è respinto per sempre).
        payload = {
          ticket: @ticket.code,
          run_id: held_lease_run_id(@ticket, Current.account, active_only: fresh_run) || new_lease_run_id("web")
        }
        payload[:ttl_seconds] = TTL_SECONDS if ttl

        {
          organization: Current.organization,
          holder: ::Agents::Leases::Holder.account(Current.account),
          ticket_reference: @ticket.code,
          params: payload
        }
      end

      # Il messaggio d'errore che conta è il 409: dice chi tiene il ticket, così chi ha premuto sa a
      # chi rivolgersi invece di leggere un codice.
      def feedback(result, success:)
        return { notice: success } if result.ok?

        { alert: conflict_message(result.error) || result.error.message }
      end

      def conflict_message(error)
        holder = error.details&.dig(:holder)
        return unless holder

        # format: :short e non :time_only — quest'ultimo non esiste, e un TTL di 8 ore può scavallare
        # la mezzanotte: la sola ora sarebbe ambigua. :short è dichiarato in it.yml e fornito d'ufficio
        # da Rails in inglese.
        t("member.tickets.lease.held_by",
          name: holder.dig(:held_by, :name).presence || t("member.tickets.lease.unknown_holder"),
          time: l(holder[:expires_at].in_time_zone, format: :short))
      end

      # Anti-BOLA + scoping: ticket non visibile (o di altra org) → RecordNotFound (404).
      def set_ticket
        @ticket = visible.tickets.find(params[:ticket_id])
      end
    end
  end
end
