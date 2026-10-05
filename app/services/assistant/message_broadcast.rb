# frozen_string_literal: true

module Assistant
  # Puts a bubble on the conversation stream: appended when it is born, replaced when it changes.
  # One place for the stream name and the target, shared by the services and the voice job. CYRA-908
  module MessageBroadcast
    module_function

    def append(message)
      Turbo::StreamsChannel.broadcast_append_to(
        Realtime::Streams.assistant_conversation(message.conversation),
        target: "assistant_messages_#{message.conversation_id}",
        partial: "member/assistant_conversations/message", locals: { message: message }
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
