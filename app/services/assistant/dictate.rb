# frozen_string_literal: true

module Assistant
  # Dictation into a field: turns a recording into its text and hands the text back, without
  # writing a message or keeping the audio. Neither the audio nor the text is logged.
  class Dictate < ApplicationService
    def initialize(audio:)
      @audio = audio
    end

    def call
      return Result.err(::Ai::Feature.disabled_error(:assistant_voice)) if ::Ai::Feature.disabled?(:assistant_voice)
      error = AudioUpload.error(@audio)
      return Result.err(error) if error

      text = Ai::Llm::Client.new.transcribe(audio: @audio.tempfile, filename: "voice.wav").to_s.strip
      return Result.err(failure(:not_heard, Constants::NOT_HEARD_CODE, :unprocessable_content)) if text.blank?

      Result.ok(text.truncate(Constants::MAX_MESSAGE_CHARS))
    rescue Ai::Llm::Client::Error => e
      Rails.logger.warn("[assistant] dictation failed code=#{e.code}")
      Result.err(failure(:failed, e.code, :bad_gateway))
    rescue KeyError
      # Gateway not configured: an operating fault, told with the same code the chat uses.
      Result.err(failure(:failed, "R502-LLM-002", :bad_gateway))
    end

    private

    def failure(key, code, status)
      AppError.new(I18n.t("member.assistant.voice.#{key}"), code: code, status: status)
    end
  end
end
