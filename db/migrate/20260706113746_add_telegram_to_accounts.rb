class AddTelegramToAccounts < ActiveRecord::Migration[8.1]
  def change
    # Collegamento Telegram PERSONALE (globale, non per-org): il chat_id verso cui il bot ufficiale
    # manda i DM di notifica. Popolato dal webhook /start (Telegram::LinkAccount). Nullo = scollegato
    # → il canale Telegram non è attivabile e la pagina mostra la guida di attivazione.
    add_column :accounts, :telegram_chat_id, :string
    add_column :accounts, :telegram_username, :string
    add_column :accounts, :telegram_linked_at, :datetime

    add_index :accounts, :telegram_chat_id, unique: true, where: "telegram_chat_id IS NOT NULL"
  end
end
