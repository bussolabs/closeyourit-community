# frozen_string_literal: true

module Ui
  # Microphone of the member topbar and the blurred overlay with the waves. The button stays hidden
  # until the browser proves it can record; the switches hide everything. CYRA-908
  class VoiceComponent < BaseComponent
    def render?
      return false if ::Ai::Feature.disabled?(:assistant_voice)

      ::Ai::Feature.enabled?(:assistant_chat)
    end

    def labels
      %w[listening hint silent_hint sending denied_title denied_hint failed_title device_unnamed].index_with do |key|
        t("member.assistant.voice.#{key}", time: "%{time}", n: "%{n}")
      end.to_json
    end
  end
end
