# frozen_string_literal: true

module Chat
  # Soft-elimina un messaggio (autorizzazione già verificata dal controller) e RIMUOVE la bolla in
  # realtime dallo stream della conversazione: chi ha il thread aperto in un'altra scheda la vede
  # sparire subito (la show filtra su .kept, quindi il remove è coerente col reload). Twin di
  # Chat::PostMessage#broadcast, lato eliminazione.
  class DeleteMessage < ApplicationService
    def initialize(message:)
      @message = message
    end

    def call
      @message.soft_delete!
      broadcast_remove
      Result.ok(@message)
    end

    private

    def broadcast_remove
      Turbo::StreamsChannel.broadcast_remove_to(
        Realtime::Streams.chat_conversation(@message.conversation),
        target: ActionView::RecordIdentifier.dom_id(@message)
      )
    end
  end
end
