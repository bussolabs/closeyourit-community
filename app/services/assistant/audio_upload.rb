# frozen_string_literal: true

module Assistant
  # The checks every uploaded recording passes before anything is done with it: it is there, it is
  # not too large, it is the format the microphone produces. Returns the AppError, or nil when fine.
  module AudioUpload
    module_function

    def error(audio)
      return build(:missing, Constants::NO_AUDIO_CODE, :unprocessable_content) unless audio.respond_to?(:content_type)
      return build(:too_large, Constants::AUDIO_TOO_LARGE_CODE, :content_too_large) if audio.size > Constants::MAX_AUDIO_BYTES

      build(:type, Constants::AUDIO_TYPE_CODE, :unsupported_media_type) unless
        Constants::AUDIO_CONTENT_TYPES.include?(audio.content_type)
    end

    def build(key, code, status)
      AppError.new(I18n.t("member.assistant.voice.errors.#{key}"), code: code, status: status)
    end
  end
end
