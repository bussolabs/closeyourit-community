# frozen_string_literal: true

module Member
  # Endpoint del pannello di ricerca globale. Ogni dominio parte dallo scope visibile già definito
  # in VisibleResources: stesso confine anti-BOLA delle rispettive pagine index/show.
  class SearchesController < Member::BaseController
    permission_not_required "Ricerca globale: ogni dominio parte dallo scope già visibile, lo stesso confine delle " \
                            "rispettive pagine."

    # Il layout member rende gia' il pannello di ricerca, e dentro c'e' un `turbo-frame` con QUESTO
    # id, quello che mostra l'invito «cerca nel workspace». Rispondendo dentro il layout, la pagina
    # tornava con DUE frame dello stesso id: Turbo prende il primo e il primo e' l'invito, quindi i
    # risultati non comparivano mai. Il servizio li trovava e li rendeva — finivano nel secondo frame,
    # che nessuno guardava.
    #
    # Senza layout quando la richiesta viene da un frame; col layout quando qualcuno atterra su
    # /member/search per suo conto, perche' li' un frammento nudo non e' una pagina.
    layout -> { turbo_frame_request? ? false : "member" }

    def index
      @query = params[:q].to_s.strip.first(100)
      @type = params[:type].to_s
      @found = Search::Global.call(
        query: @query, type: @type, visible: visible,
        viewer: Current.account, organization: Current.organization,
        nav_items: @query.length >= Search::Global::MIN_QUERY_LENGTH ? helpers.search_nav_entries : []
      )
    end
  end
end
