# frozen_string_literal: true

module Member
  module Tickets
    # Preferenza personale delle colonne RIDOTTE della board (CYRA-390). Collassare o espandere una
    # colonna è una scelta dell'utente, ricordata alla visita successiva: vive in
    # Accounts::Account#board_collapsed_statuses (jsonb preferences), per code di status.
    #
    # POST collassa (aggiunge il code), DELETE espande (lo rimuove). Idempotenti: il setter del model
    # deduplica. In collapse il code è ammesso SOLO se corrisponde a uno status attivo dell'org — così
    # nessuno può gonfiare le preferenze con code arbitrari; in expand si rimuove sempre, anche un code
    # ormai inesistente, per lasciare pulito. Nessun corpo da rendere: 204, il DOM è già aggiornato in
    # modo ottimistico dal controller Stimulus della board.
    #
    # Al PRIMO tocco (board mai configurata) la lista non parte da vuoto ma dal DEFAULT materializzato —
    # le colonne concluse ridotte — così aprire UNA conclusa non riapre anche le altre, e da lì la lista
    # esplicita comanda (fonte unica con Member::TicketsController#board_collapsed_codes).
    class CollapsedColumnsController < Member::BaseController
      permission_not_required "Colonne ridotte della board: preferenza personale, scritta sul proprio account."

      def create
        code = params[:code].to_s
        persist { |codes| codes | [ code ] } if Current.organization.ticket_statuses.active.exists?(code: code)
        head :no_content
      end

      def destroy
        persist { |codes| codes - [ params[:code].to_s ] }
        head :no_content
      end

      private

      def persist
        account = Current.account
        base = account.board_columns_configured? ? account.board_collapsed_statuses : default_collapsed_codes
        account.update!(board_collapsed_statuses: yield(base))
      end

      # Default materializzato al primo tocco: la stessa fonte della board (CYRA-691) — concluse
      # ripiegate solo se vuote nella finestra recente. Se divergesse, espandere una colonna ne
      # ripiegherebbe un'altra alla visita successiva.
      def default_collapsed_codes
        Ticketing::BoardDefaults.collapsed_codes(Current.organization.ticket_statuses.active.to_a,
                                                 visible.tickets).to_a
      end
    end
  end
end
