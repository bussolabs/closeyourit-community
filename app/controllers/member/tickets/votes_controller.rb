# frozen_string_literal: true

module Member
  module Tickets
    # Voto (upvote) su un ticket. Singleton resource: l'identità è il ticket parent (1 voto/account),
    # il client non conosce l'id del voto. PUT crea (idempotente), DELETE rimuove (idempotente).
    # Vota chiunque vede il ticket (visible.tickets → 404 se non lo vede, anti-BOLA).
    class VotesController < Member::BaseController
      permission_not_required "Votare un ticket è baseline di chi lo vede: il catalogo dei permessi non ha una " \
                              "chiave per il voto."

      before_action :set_ticket

      # PUT: crea il voto dell'account corrente se non esiste. Idempotente: ri-votare (o un doppio
      # submit che collide sull'indice unico) resta un successo, niente errore.
      def update
        @ticket.votes.find_or_create_by!(account: Current.account)
        redirect_back fallback_location: member_ticket_path(@ticket), notice: t("member.tickets.vote.added")
      rescue ActiveRecord::RecordNotUnique
        redirect_back fallback_location: member_ticket_path(@ticket), notice: t("member.tickets.vote.added")
      end

      # DELETE: rimuove il voto dell'account corrente (idempotente). destroy_all (non delete_all)
      # per far scattare il counter_cache su votes_count.
      def destroy
        @ticket.votes.where(account: Current.account).destroy_all
        redirect_back fallback_location: member_ticket_path(@ticket), notice: t("member.tickets.vote.removed")
      end

      private

      # Anti-BOLA + scoping: ticket non visibile (o di altra org) → RecordNotFound (404).
      def set_ticket
        @ticket = visible.tickets.find(params[:ticket_id])
      end
    end
  end
end
