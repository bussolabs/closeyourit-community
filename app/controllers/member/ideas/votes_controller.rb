# frozen_string_literal: true

module Member
  module Ideas
    # Voto (upvote) su un'idea. Singleton resource: l'identità è l'idea parent (1 voto/account),
    # PUT crea (idempotente), DELETE rimuove (idempotente). Vota chiunque vede l'idea
    # (visible.ideas → 404, anti-BOLA); le idee congelate non si votano più.
    class VotesController < Member::BaseController
      permission_not_required "Votare un'idea è baseline di chi la vede: il catalogo dei permessi non ha una chiave " \
                              "per il voto."

      before_action :set_idea
      before_action :require_open_idea

      def update
        @idea.votes.find_or_create_by!(account: Current.account)
        redirect_back fallback_location: member_idea_path(@idea), notice: t("member.ideas.vote.added")
      rescue ActiveRecord::RecordNotUnique
        redirect_back fallback_location: member_idea_path(@idea), notice: t("member.ideas.vote.added")
      end

      def destroy
        # destroy_all (non delete_all) per far scattare il counter_cache su votes_count.
        @idea.votes.where(account: Current.account).destroy_all
        redirect_back fallback_location: member_idea_path(@idea), notice: t("member.ideas.vote.removed")
      end

      private

      def set_idea
        @idea = visible.ideas.find(params[:idea_id])
      end

      def require_open_idea
        return if @idea.status_open?

        redirect_back fallback_location: member_idea_path(@idea), alert: t("ideas.errors.locked")
      end
    end
  end
end
