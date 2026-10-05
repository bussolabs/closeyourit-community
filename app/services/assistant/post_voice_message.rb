# frozen_string_literal: true

module Assistant
  # Records a spoken message: the user bubble is born `transcribing` with the audio attached only
  # while TranscribeJob turns it into text and starts the reply. Gates and upload checks come
  # first, so a refused request writes nothing. CYRA-908
  class PostVoiceMessage < ApplicationService
    def initialize(conversation:, audio:)
      @conversation = conversation
      @audio = audio
    end

    def call
      return Result.err(::Ai::Feature.disabled_error(:assistant_chat)) if ::Ai::Feature.disabled?(:assistant_chat)
      return Result.err(::Ai::Feature.disabled_error(:assistant_voice)) if ::Ai::Feature.disabled?(:assistant_voice)
      error = AudioUpload.error(@audio)
      return Result.err(error) if error

      message = persist
      MessageBroadcast.append(message)
      Assistant::TranscribeJob.perform_later(message_id: message.id)
      Result.ok(message)
    end

    private

    # The attachment is uploaded on commit, so the job queued after this block finds the file.
    def persist
      ActiveRecord::Base.transaction do
        @conversation.messages.create!(role: :user, status: :transcribing, content: nil, transcribed: true,
                                       organization_id: @conversation.organization_id, audio: @audio)
                     .tap { |message| @conversation.update!(last_message_at: message.created_at) }
      end
    end
  end
end
