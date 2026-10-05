# frozen_string_literal: true

module Ticketing
  # Push realtime di un commento appena scritto sulla discussione del ticket. Estratto da
  # Ticketing::AddComment (CYRA-220) perché ora i commenti non nascono più da un posto solo: anche
  # Ticketing::RecordReport e il ciclo di chiarimento scrivono righe di servizio, e tre copie di
  # questo blocco sarebbero tre occasioni di far divergere i target dei broadcast.
  #
  # Va chiamato SEMPRE dopo il commit. Alcuni chiamanti (Agents::Clarifications::Ask) girano dentro
  # una transazione esterna: un broadcast lì dentro spedirebbe un frammento che referenzia righe non
  # ancora visibili agli altri processi.
  class BroadcastComment < ApplicationService
    def initialize(comment:)
      @comment = comment
      @ticket = comment.ticket
    end

    def call
      stream = Realtime::Streams.ticket(@ticket)
      append_comment(stream)
      replace_comments_count(stream)
      replace_watchers_count(stream)
      Result.ok(@comment)
    end

    private

    # id stabile dal dom_id → Turbo de-duplica per chi ha già la pagina fresca dal redirect: niente
    # doppione. Il commento NON è un Ticketing::Event, quindi non c'è doppio append con RecordActivity.
    def append_comment(stream)
      Turbo::StreamsChannel.broadcast_append_to(
        stream, target: "ticket_timeline_#{@ticket.id}",
        partial: "member/tickets/comment",
        locals: { comment: @comment, ticket: @ticket, can_manage: false }
      )
    end

    def replace_comments_count(stream)
      Turbo::StreamsChannel.broadcast_replace_to(
        stream, target: "ticket_comments_count_#{@ticket.id}",
        partial: "member/tickets/comments_count",
        locals: { ticket: @ticket, count: @ticket.comments.count }
      )
    end

    # L'autore si è appena auto-iscritto come watcher (Ticketing::AddComment#notify).
    def replace_watchers_count(stream)
      Turbo::StreamsChannel.broadcast_replace_to(
        stream, target: "#{ActionView::RecordIdentifier.dom_id(@ticket)}_watchers",
        partial: "member/tickets/watchers_count",
        locals: { ticket: @ticket, count: @ticket.subscriptions.count }
      )
    end
  end
end
