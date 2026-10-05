# frozen_string_literal: true

module Cli
  module V1
    module Ideas
      # Commenti di un'idea via CLI. Commentare è baseline (chi vede il progetto); il congelamento
      # (converted/archived) è garantito dai service. Eliminare = autore OPPURE
      # `ideas.comment.delete_any` — specchio di Member::Ideas::CommentsController.
      class CommentsController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_idea

        def index
          # includes(:author): il serializer espone il nome dell'autore (no N+1, guard prosopite).
          comments, meta = paginate(@idea.comments.includes(:author))
          render_ok(IdeaCommentSerializer.new(comments), meta: meta)
        end

        def create
          result = ::Ideas::AddComment.call(idea: @idea, author: Current.account, params: comment_params)
          if result.ok?
            render_created(IdeaCommentSerializer.new(result.value))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        def destroy
          comment = @idea.comments.find(params[:id])
          unless comment.author_id == Current.account.id
            require_permission!("ideas.comment.delete_any", scope: @project) or return
          end

          result = ::Ideas::DeleteComment.call(comment:)
          if result.ok?
            render_no_content
          else
            render_error(result.error.code, result.error.message, status: result.error.status)
          end
        end

        private

        def set_idea
          @idea = @project.ideas.find(params[:idea_id])
        end

        def comment_params
          params.permit(:body)
        end
      end
    end
  end
end
