# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # Voto (upvote) del ticket via CLI. Singleton: l'identità è il ticket parent (1 voto/account, il
      # client non conosce l'id del voto). PUT vota (idempotente), DELETE rimuove (idempotente). Vota
      # chiunque vede il ticket (set_project! → visibilità Fase E, anti-BOLA 404). Logica banale sul
      # model Connections::TicketVote (niente service dedicato), come Member::Tickets::VotesController.
      class VotesController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_ticket

        # PUT: crea il voto dell'account corrente se non esiste. Idempotente: ri-votare (o un doppio
        # submit che collide sull'indice unico) resta un successo, niente errore.
        def update
          @ticket.votes.find_or_create_by!(account: Current.account)
          render_vote
        rescue ActiveRecord::RecordNotUnique
          render_vote
        end

        # DELETE: rimuove il voto dell'account corrente (idempotente). destroy_all (non delete_all)
        # per far scattare il counter_cache su votes_count.
        def destroy
          @ticket.votes.where(account: Current.account).destroy_all
          render_vote
        end

        private

        def set_ticket
          @ticket = find_ticket!(@project, params[:ticket_id])
        end

        # Stato del voto dell'account corrente + contatore aggiornato (envelope {data}). reload: il
        # counter_cache muove la colonna votes_count in DB, l'istanza in memoria va riallineata.
        def render_vote
          @ticket.reload
          render_ok({
            ticket_id: @ticket.id,
            votes_count: @ticket.votes_count,
            voted: @ticket.votes.exists?(account: Current.account)
          })
        end
      end
    end
  end
end
