# frozen_string_literal: true

# Toggle personale per le notifiche di chat (nuovo messaggio / menzione), gemello di tickets_enabled.
# Default true: chi non tocca le preferenze riceve le notifiche di chat.
class AddChatEnabledToAlertingPreferences < ActiveRecord::Migration[8.1]
  def change
    add_column :alerting_preferences, :chat_enabled, :boolean, null: false, default: true
  end
end
