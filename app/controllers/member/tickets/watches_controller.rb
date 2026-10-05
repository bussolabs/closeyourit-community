# frozen_string_literal: true

module Member
  module Tickets
    # Watch (sottoscrizione) di un account a un ticket. Singleton resource come il voto: l'identità
    # è il ticket parent (1 iscrizione/account), il client non conosce l'id della sottoscrizione.
    # PUT iscrive (idempotente), DELETE disiscrive (idempotente). Si iscrive chiunque vede il ticket
    # (visible.tickets → 404 se non lo vede, anti-BOLA): la partecipazione è il gate.
    class WatchesController < Member::BaseController
      permission_not_required "Iscriversi agli aggiornamenti di un ticket visibile: la partecipazione è il confine."

      before_action :set_ticket

      # PUT: iscrive l'account corrente al ticket se non già iscritto. ensure_for è idempotente
      # e race-safe (un doppio submit che collide sull'indice unico resta un successo).
      def update
        Ticketing::Subscription.ensure_for(ticket: @ticket, account: Current.account, source: :manual)
        broadcast_watchers_count
        redirect_back fallback_location: member_ticket_path(@ticket), notice: t("member.tickets.watch.added")
      end

      # DELETE: rimuove la sottoscrizione dell'account corrente (idempotente: disiscriversi senza
      # essere iscritti non è un errore).
      def destroy
        @ticket.subscriptions.where(account: Current.account).destroy_all
        broadcast_watchers_count
        redirect_back fallback_location: member_ticket_path(@ticket), notice: t("member.tickets.watch.removed")
      end

      private

      # Realtime: aggiorna il contatore watcher per tutti i viewer del ticket. La mutazione
      # (ensure_for / destroy_all) è già committata (l'action non apre transazioni esterne). Solo il
      # numero è condiviso; lo stato del pulsante watch/unwatch resta per-viewer (l'attore lo riottiene
      # col redirect). Stream tenant-prefissato da Realtime::Streams.
      def broadcast_watchers_count
        Turbo::StreamsChannel.broadcast_replace_to(
          Realtime::Streams.ticket(@ticket),
          target: "#{ActionView::RecordIdentifier.dom_id(@ticket)}_watchers",
          partial: "member/tickets/watchers_count",
          locals: { ticket: @ticket, count: @ticket.subscriptions.count }
        )
      end

      # Anti-BOLA + scoping: ticket non visibile (o di altra org) → RecordNotFound (404).
      def set_ticket
        @ticket = visible.tickets.find(params[:ticket_id])
      end
    end
  end
end
