# frozen_string_literal: true

module Assistant
  # Turns the audio of a spoken message into its text, then starts the reply as for a typed one.
  # The audio lives only for this job and is purged whatever happens; neither the audio nor the
  # text is ever logged. CYRA-908
  class TranscribeJob < ApplicationJob
    queue_as :ai

    def perform(message_id:)
      message = Assistant::Message.find_by(id: message_id)
      return unless message&.status_transcribing?
      Current.organization = message.organization # runs with this organization's AI settings (CYRA-914)

      text = transcribe(message)
      return fail_message(message, Constants::NOT_HEARD_CODE) if text.blank?

      complete(message, text)
      StartReply.call(question: message)
    rescue Ai::Llm::Client::Error => e
      fail_message(message, e.code)
    rescue KeyError
      # Gateway not configured: an operating fault, told with the same code the chat uses.
      fail_message(message, "R502-LLM-002")
    rescue StandardError => e
      Rails.logger.error("[assistant] transcription crashed message=#{message_id}: #{e.class}")
      fail_message(message, "R500-ASSISTANT-001") if message&.status_transcribing?
      raise
    ensure
      message.audio.purge if message&.audio&.attached?
    end

    private

    def transcribe(message)
      message.audio.open do |file|
        Ai::Llm::Client.new.transcribe(audio: file, filename: "voice.wav")
      end.truncate(Constants::MAX_MESSAGE_CHARS)
    end

    def complete(message, text)
      message.update!(status: :complete, content: text)
      conversation = message.conversation
      conversation.update!(title: text.truncate(60)) if conversation.title.blank?
      MessageBroadcast.replace(message)
    end

    def fail_message(message, code)
      Rails.logger.warn("[assistant] transcription failed message=#{message.id} code=#{code}")
      message.update!(status: :failed, error_code: code)
      MessageBroadcast.replace(message)
    end
  end
end
