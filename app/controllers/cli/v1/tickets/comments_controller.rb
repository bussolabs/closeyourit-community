# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # Commenti di un ticket via CLI. Commentare è baseline: chi vede il progetto (set_project! →
      # visibilità Fase E) vede il ticket e può commentare — specchio di
      # Member::Tickets::CommentsController (tutti i ruoli che vedono il ticket commentano).
      # Eliminare un commento = autore OPPURE gate `tickets.comment.delete_any`. La logica vive nei
      # service condivisi Ticketing::{AddComment,DeleteComment}; il controller è un thin adapter.
      class CommentsController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_ticket

        # Lettura = baseline (chi vede il ticket): lista cronologica dei commenti (paginata).
        # includes speculare al serializer (author + files con blob): senza, N+1 per commento.
        def index
          comments, meta = paginate(@ticket.comments.includes(:author, files_attachments: :blob))
          render_ok(CommentSerializer.new(comments), meta: meta)
        end

        def create
          result = Ticketing::AddComment.call(ticket: @ticket, author: Current.account, params: comment_params)
          if result.ok?
            render_created(CommentSerializer.new(result.value))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        def destroy
          comment = @ticket.comments.find(params[:id])
          # Autore: sempre. Altrimenti serve `tickets.comment.delete_any` (require_permission! rende
          # R403-CLIAUTH-002 su deny e ritorna false). Stessa policy di Member::Tickets::CommentsController#can_delete?.
          unless comment.author_id == Current.account.id
            require_permission!("tickets.comment.delete_any", scope: @project) or return
          end

          result = Ticketing::DeleteComment.call(comment: comment, actor: Current.account, true_actor: Current.account)
          if result.ok?
            render_no_content
          else
            render_error(result.error.code, result.error.message, status: result.error.status)
          end
        end

        private

        # Ticket dentro il progetto già scoped a visible_projects (set_project!): anti-BOLA, un ticket
        # fuori dal progetto/visibilità → RecordNotFound → R404 (mai 403). Specchio del TicketsController.
        # UUID o code umano (find_ticket! in Cli::V1::BaseController).
        def set_ticket
          @ticket = find_ticket!(@project, params[:ticket_id])
        end

        # Stesso permit di Member::Tickets::CommentsController: corpo + allegati opzionali.
        def comment_params
          params.permit(:body, files: [])
        end
      end
    end
  end
end
