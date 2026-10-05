# frozen_string_literal: true

module Cli
  module V1
    module Assistant
      # Stato di una risposta dell'assistente: l'endpoint che il client interroga a intervalli finché
      # `status` smette di essere "streaming".
      #
      # Passa per le conversazioni dell'account (non per ::Assistant::Message diretto) perché la
      # proprietà vive sulla conversazione: è il confine che impedisce di leggere la risposta altrui
      # conoscendone l'id, e insieme quello che tiene fuori i messaggi nati nel sito.
      class MessagesController < Cli::V1::BaseController
        def show
          message = ::Assistant::Message.where(conversation: conversations).find(params[:id])
          render_ok(AssistantMessageSerializer.new(message))
        end

        private

        def conversations
          ::Assistant::Conversation.for(account: Current.account, organization: Current.organization,
                                        kind: :tools)
        end
      end
    end
  end
end
