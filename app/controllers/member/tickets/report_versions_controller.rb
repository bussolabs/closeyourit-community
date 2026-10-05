# frozen_string_literal: true

module Member
  module Tickets
    # Una stesura precedente del resoconto (CYRA-265). Sola lettura: un resoconto non si riscrive mai
    # (attr_readonly su Ticketing::Report), correggerlo significa scriverne uno nuovo — quindi qui non
    # c'è niente da modificare, solo da rileggere.
    #
    # Il param è il NUMERO di versione, non l'id: l'indirizzo dice da solo cosa si sta guardando
    # (/tickets/:id/report/versions/1) e resta valido anche se la riga cambia id. È lo stesso
    # `to_param` che il modello dichiara.
    class ReportVersionsController < Member::BaseController
      permission_not_required "Stesura precedente di un resoconto: sola lettura dentro un ticket visibile, niente da " \
                              "modificare."

      def show
        @ticket = visible.tickets.find(params[:ticket_id])
        # find_by! e non find: il param è la versione, e una versione inesistente è un 404 come un
        # ticket inesistente — non un 500 per record mancante su una colonna che non è la chiave.
        @report = @ticket.reports.find_by!(version: params[:version])
        @current_version = @ticket.reports.maximum(:version)
      end
    end
  end
end
