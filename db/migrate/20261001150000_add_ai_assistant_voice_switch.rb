# frozen_string_literal: true

# Emergency brake for the voice assistant: transcription spends a gateway call per message on top
# of the reply, so it can be stopped without silencing the typed chat. Default on. CYRA-908
class AddAiAssistantVoiceSwitch < ActiveRecord::Migration[8.1]
  def change
    add_column :settings_global, :ai_assistant_voice_enabled, :boolean, null: false, default: true
  end
end
