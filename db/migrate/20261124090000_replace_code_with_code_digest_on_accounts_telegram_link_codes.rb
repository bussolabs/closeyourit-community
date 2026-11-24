# frozen_string_literal: true

# Il codice del deep-link /start non resta più in chiaro: si salva solo il suo SHA-256 (CYRA-1264).
# I codici già emessi sono in chiaro e si cancellano subito (la purga avviene solo al conio successivo):
# chi aveva la pagina aperta la ricarica e riceve un codice nuovo, che vale comunque solo un'ora.
class ReplaceCodeWithCodeDigestOnAccountsTelegramLinkCodes < ActiveRecord::Migration[8.1]
  def up
    execute "DELETE FROM accounts_telegram_link_codes"

    remove_index :accounts_telegram_link_codes, :code
    remove_column :accounts_telegram_link_codes, :code
    add_column :accounts_telegram_link_codes, :code_digest, :string, null: false,
               comment: "SHA-256 del codice del deep-link: il codice in chiaro esiste solo nel link"
    add_index :accounts_telegram_link_codes, :code_digest, unique: true
  end

  def down
    execute "DELETE FROM accounts_telegram_link_codes"

    remove_index :accounts_telegram_link_codes, :code_digest
    remove_column :accounts_telegram_link_codes, :code_digest
    add_column :accounts_telegram_link_codes, :code, :string, null: false
    add_index :accounts_telegram_link_codes, :code, unique: true
  end
end
