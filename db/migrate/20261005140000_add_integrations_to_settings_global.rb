# GitHub App and Telegram values set from Valhalla (CYRA-914). Empty columns on the one-row settings
# table: until someone fills them, the environment variables keep working as before.
class AddIntegrationsToSettingsGlobal < ActiveRecord::Migration[8.1]
  def change
    change_table :settings_global, bulk: true do |t|
      t.string :gh_app_id
      t.string :gh_app_slug
      t.string :gh_app_client_id
      t.text :gh_app_client_secret
      t.text :gh_app_private_key
      t.text :gh_webhook_secret
      t.text :telegram_bot_token
      t.string :telegram_bot_username
      t.text :telegram_webhook_secret
    end
  end
end
