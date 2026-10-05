# frozen_string_literal: true

# CYRA-170 (C) — codici di recupero 2FA monouso.
# Un account con 2FA attivo ha 10 codici di recupero: alternativa al codice TOTP quando l'utente perde
# l'authenticator. In DB solo il DIGEST SHA-256 del codice (mai il plaintext, mostrato una volta sola al
# setup), come token_digest di Accounts::ApiToken. used_at marca il consumo (monouso).
class CreateAccountsOtpRecoveryCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts_otp_recovery_codes, id: :uuid do |t|
      t.references :account, null: false, type: :uuid,
                   foreign_key: { to_table: :accounts, on_delete: :cascade }, index: false
      t.string :code_digest, null: false
      t.datetime :used_at
      t.timestamps
    end

    add_index :accounts_otp_recovery_codes, %i[account_id code_digest], unique: true
    add_index :accounts_otp_recovery_codes, :account_id
  end
end
