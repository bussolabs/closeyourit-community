# frozen_string_literal: true

# Codice corto monouso per il deep-link /start del bot Telegram. Sostituisce il token firmato
# (generates_token_for :telegram_link, ~238 char) che NON entra nel parametro `start` di Telegram
# (max 64 char, solo [A-Za-z0-9_-]) → il collegamento via pulsante non funzionava. Il codice
# (SecureRandom.urlsafe_base64 = 32 char validi) mappa a un account con scadenza, ed è single-use.
class CreateAccountsTelegramLinkCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts_telegram_link_codes, id: :uuid do |t|
      t.timestamps

      t.references :account, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts, on_delete: :cascade }

      t.string   :code,       null: false
      t.datetime :expires_at, null: false

      t.index :code, unique: true
      t.index :expires_at
    end
  end
end
