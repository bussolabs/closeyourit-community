# frozen_string_literal: true

module Cli
  module V1
    module Ideas
      # Voto (upvote) dell'idea via CLI. Singleton: identità = idea parent (1 voto/account). PUT
      # vota (idempotente), DELETE rimuove (idempotente). Vota chiunque vede il progetto; le idee
      # congelate (converted/archived) non si votano più — specchio di Member::Ideas::VotesController.
      class VotesController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_idea
        before_action :require_open_idea

        def update
          @idea.votes.find_or_create_by!(account: Current.account)
          render_vote
        rescue ActiveRecord::RecordNotUnique
          render_vote
        end

        def destroy
          # destroy_all (non delete_all) per far scattare il counter_cache su votes_count.
          @idea.votes.where(account: Current.account).destroy_all
          render_vote
        end

        private

        def set_idea
          @idea = @project.ideas.find(params[:idea_id])
        end

        def require_open_idea
          return if @idea.status_open?

          render_error("R422-IDEA-002", I18n.t("ideas.errors.locked"), status: :unprocessable_content)
        end

        # Stato del voto dell'account corrente + contatore aggiornato. reload: il counter_cache
        # muove la colonna in DB, l'istanza in memoria va riallineata.
        def render_vote
          @idea.reload
          render_ok({
            idea_id: @idea.id,
            votes_count: @idea.votes_count,
            voted: @idea.votes.exists?(account: Current.account)
          })
        end
      end
    end
  end
end
