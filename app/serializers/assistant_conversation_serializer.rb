# frozen_string_literal: true

# Una conversazione con l'assistente per i client JSON (canale CLI). I messaggi si includono solo
# dove servono davvero (show): nell'elenco appesantirebbero la risposta senza che nessuno li legga.
class AssistantConversationSerializer < ApplicationSerializer
  attributes :id, :title, :last_message_at, :created_at

  attribute :messages, if: proc { params[:with_messages] } do |conversation|
    AssistantMessageSerializer.new(conversation.messages.chronological).serializable_hash
  end
end
