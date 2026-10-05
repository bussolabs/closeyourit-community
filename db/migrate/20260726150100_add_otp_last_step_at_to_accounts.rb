# frozen_string_literal: true

# CYRA-170 (FIX-8) — anti-replay del codice TOTP.
# Additiva e nullable. Registra l'istante (inizio intervallo) dell'ultimo codice TOTP consumato con
# successo: verify_otp lo passa a ROTP come `after:` così lo STESSO codice (o uno di un intervallo
# precedente) non è più riutilizzabile nella sua finestra di validità (~90s). nil = nessun codice ancora
# consumato (nessun filtro). Vedi Accounts::Account#verify_otp.
class AddOtpLastStepAtToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :otp_last_step_at, :datetime
  end
end
