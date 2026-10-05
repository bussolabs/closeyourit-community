# frozen_string_literal: true

# CYRA-170 (C) — 2FA TOTP sull'account.
# - otp_secret: seme TOTP Base32, cifrato at-rest (ActiveRecord::Encryption non-deterministico, come
#   Secrets::Variable). Colonna string: in PostgreSQL è varchar illimitato, il ciphertext non viene troncato.
# - otp_enabled_at: quando il 2FA è stato attivato (nil = non attivo). È la sorgente di #otp_enabled?.
# Entrambe nullable e additive: gli account esistenti restano senza 2FA finché non lo configurano.
class AddOtpToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :otp_secret, :string
    add_column :accounts, :otp_enabled_at, :datetime
  end
end
