# frozen_string_literal: true

module Cli
  module V1
    module Assistant
      # Le conversazioni con l'assistente che legge i dati, possedute da chi le ha aperte.
      #
      # Nessun controllo di permessi oltre alla proprietà: una conversazione è privata di chi l'ha
      # aperta, e `.for` è insieme lo scope e il confine — un id altrui non dà 403 ma 404, perché
      # dire "esiste ma non è tua" è già dire qualcosa. Il `kind` fa parte di quel confine: le
      # conversazioni nate nel sito, che sono di un altro assistente, da qui non si vedono.
      #
      # Il namespace è `Cli::V1::Assistant::`, il dominio è `::Assistant::`: dentro qui il prefisso
      # esplicito è obbligatorio, o Ruby risolve sulla costante annidata.
      class ConversationsController < Cli::V1::BaseController
        def index
          records, meta = paginate(scope.ordered)
          render_ok(AssistantConversationSerializer.new(records), meta: meta)
        end

        def show
          conversation = scope.includes(:messages).find(params[:id])
          render_ok(AssistantConversationSerializer.new(conversation, params: { with_messages: true }))
        end

        def create
          conversation = scope.create!(title: params[:title], kind: :tools)
          render_created(AssistantConversationSerializer.new(conversation))
        end

        def destroy
          scope.find(params[:id]).destroy!
          render_no_content
        end

        private

        def scope
          ::Assistant::Conversation.for(account: Current.account, organization: Current.organization,
                                        kind: :tools)
        end
      end
    end
  end
end
