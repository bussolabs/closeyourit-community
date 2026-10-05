# frozen_string_literal: true

module Member
  module Tickets
    # CYRA-364 — rifornisce il campo «Ticket collegato» mentre si digita: poche voci, cercate sul
    # server per codice o titolo, invece delle duecento di tutta l'organizzazione caricate insieme
    # alla pagina. Consumato da `ui--remote-options` (JSON), sempre dentro `visible.tickets`.
    #
    # Nessun gate oltre la visibilità: sono gli stessi ticket che il campo mostrava già: cambia
    # quanti se ne caricano e quando, non chi può vederli.
    class LinkableController < Member::BaseController
      permission_not_required "Suggerisce ticket già visibili mentre si scrive: nessun dato oltre quelli che il " \
                              "campo mostrava."

      def index
        tickets = ::Ticketing::LinkableTickets.call(
          scope: visible.tickets, query: params[:q],
          project_ids: context_project_ids, all: params[:all].present?
        )

        render json: { data: tickets.map { |ticket| { id: ticket.id, label: "#{ticket.code} · #{ticket.title}" } } }
      end

      private

      # Contesto: il progetto indicato, oppure i progetti a cui il team scelto nel form ha accesso. Team assente (o senza accessi
      # diretti) → nessun contesto, e il service cerca su tutto il visibile.
      def context_project_ids
        # CYRA-941 — a help desk request joins only a ticket of its own project.
        return visible.projects.where(id: params[:project_id]).pluck(:id).presence if params[:project_id].present?
        return nil if params[:team_id].blank?

        Connections::TeamProjectAccess.where(team_id: visible.teams.where(id: params[:team_id]).select(:id))
                                      .pluck(:project_id).presence
      end
    end
  end
end
