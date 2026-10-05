# frozen_string_literal: true

# Marks a user message that came from the microphone, so its bubble offers "correct and resend".
# The audio itself is an Active Storage attachment that lives only while it is transcribed. CYRA-908
class AddTranscribedToAssistantMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :assistant_messages, :transcribed, :boolean, null: false, default: false
  end
end
