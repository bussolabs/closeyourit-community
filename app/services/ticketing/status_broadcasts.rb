# frozen_string_literal: true

module Ticketing
  # Broadcast realtime post-commit di un cambio di stato: page-refresh della board del progetto e
  # badge stato nello stream della ticket-show. Estratto da ChangeStatus per essere condiviso con le
  # decisioni di review (RejectReview/ApproveReview), che cambiano stato fuori da ChangeStatus ma
  # devono muovere il board allo stesso modo. Va chiamato SOLO dopo il commit della transazione.
  module StatusBroadcasts
    # dom_id(ticket) → "ticketing_ticket_<id>": l'id che la ticket-show usa per il badge stato.
    include ActionView::RecordIdentifier

    private

    # Board: solo un segnale di refresh (action="refresh"), niente HTML. Prima qui si spediva la card
    # renderizzata (remove + append su board_column_<status_id>) e i conteggi org-wide sullo stream
    # org_board — che è condiviso da tutta l'organizzazione, mentre la board è filtrata per progetto
    # da Authorization::VisibleScope: un membro con accesso a due progetti si vedeva comparire card e
    # totali di tutti gli altri (CYRA-257). Col refresh ogni viewer ri-fetcha /member/tickets con la
    # PROPRIA sessione e i propri params, quindi scope, conteggi e filtri attivi tornano corretti per
    # ciascuno; e lo stream è per-progetto, quindi chi il progetto non lo vede non è nemmeno iscritto.
    # Throttlato (leading + un solo trailing) come gli altri path realtime: Realtime::ThrottledRefresh.
    #
    # Lo stream ticket(ticket) aggiorna il badge stato nella ticket-show: resta un replace mirato,
    # è per-ticket e la show è già gated da visible.tickets.
    # `dependents: false` per chi cambia stato a PIÙ ticket nella stessa richiesta (oggi
    # Home::Approvals::BulkApprove): il refresh delle board dei dependents lo fa il chiamante UNA volta
    # sul lotto intero, altrimenti sarebbe una query per ticket dentro il loop — un N+1 vero, che il
    # guard Prosopite fa fallire già alla seconda card accettata. Il resto del broadcast resta
    # per-ticket: sono la board del suo progetto e il badge della sua show, non aggregabili.
    def broadcast_status_change(ticket:, dependents: true)
      Realtime::ThrottledRefresh.call(Realtime::Streams.project_board(ticket.project))
      broadcast_dependents_board(ticket) if dependents
      Turbo::StreamsChannel.broadcast_replace_to(
        Realtime::Streams.ticket(ticket), target: "#{dom_id(ticket)}_status",
        partial: "member/tickets/status_badge", locals: { ticket: ticket }
      )
      # CYRA-819 — sul telefono lo stato si legge dal riepilogo in testa alla pagina, non dal
      # pannello Dettagli, che la griglia impilata spinge oltre due schermate più giù. Serve un
      # SECONDO messaggio, non un secondo elemento con lo stesso id: due elementi omonimi fanno
      # aggiornare a Turbo soltanto il primo, e l'altro resterebbe fermo sullo stato vecchio —
      # esattamente il posto in cui si guarda prima di decidere. Il riepilogo esiste solo sotto lg,
      # ma il messaggio parte comunque: chi sta su schermo largo lo riceve e non trova il bersaglio,
      # che per Turbo è un no-op.
      Turbo::StreamsChannel.broadcast_replace_to(
        Realtime::Streams.ticket(ticket), target: "#{dom_id(ticket)}_mobile_summary",
        partial: "member/tickets/mobile_summary", locals: { ticket: ticket }
      )
    end

    # Badge "bloccato" dei DEPENDENTS (CYRA-82): le card dei ticket che dipendono da questo vivono sulla
    # board del LORO progetto (cross-project intra-org ammesso). Quando questo ticket cambia stato — done
    # fa cadere il badge, una riapertura lo rialza — quelle board vanno rinfrescate, non solo quella di
    # questo ticket. La logica (query unica, progetti distinti, esclusione di quelli già rinfrescati)
    # vive in Ticketing::DependentsBoardRefresh, che accetta anche un LOTTO: qui il lotto è un ticket
    # solo. Post-commit come il resto; con nessun dependent la query torna vuota → no-op.
    def broadcast_dependents_board(ticket)
      DependentsBoardRefresh.call(tickets: ticket)
    end
  end
end
