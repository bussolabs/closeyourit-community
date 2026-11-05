# frozen_string_literal: true

module Assistant
  # Puts a bubble on the conversation stream: appended when it is born, replaced when it changes.
  # One place for the stream name and the target, shared by the services and the voice job. CYRA-908
  module MessageBroadcast
    module_function

    # Bubbles of one conversation travel in a single broadcast, in the given order: two broadcasts
    # sent close together can reach the panel swapped, a single one cannot. CYRA-1084
    def append(*messages)
      conversation = messages.first.conversation
      Turbo::StreamsChannel.broadcast_append_to(
        Realtime::Streams.assistant_conversation(conversation),
        target: "assistant_messages_#{conversation.id}",
        partial: "member/assistant_conversations/message", collection: messages, as: :message
      )
    end

    def replace(message)
      Turbo::StreamsChannel.broadcast_replace_to(
        Realtime::Streams.assistant_conversation(message.conversation),
        target: ActionView::RecordIdentifier.dom_id(message),
        partial: "member/assistant_conversations/message", locals: { message: message }
      )
    end
  end
end
