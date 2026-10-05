class AddWebhookSecretToAlertingChannels < ActiveRecord::Migration[8.1]
  # Colonna cifrata at-rest (AR::Encryption la scrive in-place, ciphertext > plaintext → text).
  # Sostituisce config["secret"] plaintext del JSONB; il backfill avviene nella migration successiva.
  def change
    add_column :alerting_channels, :webhook_secret, :text
  end
end
