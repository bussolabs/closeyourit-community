# frozen_string_literal: true

module Ticketing
  # Elimina un commento e registra l'evento `comment_deleted` (il ticket resta → va in timeline).
  # In transazione: o elimina+logga o niente. L'autorizzazione (autore o admin/owner) resta nel
  # controller. Result pattern.
  class DeleteComment < ApplicationService
    def initialize(comment:, actor: nil, true_actor: nil)
      @comment = comment
      @actor = actor
      @true_actor = true_actor
    end

    def call
      return Result.err(AppError.new("I commenti automatici sono parte dell'audit e non possono essere eliminati",
                                     code: "R409-COMMENT-001", status: :conflict)) if @comment.automation_generated?

      ticket = @comment.ticket
      # author_name snapshottato: l'evento è audit (chi ha eliminato il commento DI CHI) e va
      # mostrato nella timeline; resiste alla cancellazione dell'autore.
      author_name = @comment.author&.name
      ApplicationRecord.transaction do
        # Protocollo condiviso col claim queue: ticket prima delle righe figlie. Evita il ciclo
        # ticket→commento / commento→FK ticket durante una cancellazione concorrente al claim.
        ticket.lock!
        @comment.lock!
        @comment.destroy!
        RecordActivity.call(ticket: ticket, actor: @actor, true_actor: @true_actor,
                            action: "comment_deleted", data: { author_name: author_name })
      end
      # Realtime dopo il commit (destroy persistito): rimuove la bolla dalla timeline e aggiorna il
      # contatore. L'evento `comment_deleted` entra in timeline via RecordActivity (after-commit).
      broadcast_removal(ticket)
      Result.ok(@comment)
    end

    private

    def broadcast_removal(ticket)
      stream = Realtime::Streams.ticket(ticket)
      Turbo::StreamsChannel.broadcast_remove_to(stream, target: ActionView::RecordIdentifier.dom_id(@comment))
      Turbo::StreamsChannel.broadcast_replace_to(
        stream, target: "ticket_comments_count_#{ticket.id}",
        partial: "member/tickets/comments_count",
        locals: { ticket: ticket, count: ticket.comments.count }
      )
    end
  end
end
