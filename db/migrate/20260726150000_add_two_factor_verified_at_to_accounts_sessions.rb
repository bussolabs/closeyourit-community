# frozen_string_literal: true

# CYRA-170 (FIX-5) — marca la sessione che ha superato il secondo fattore al login.
# Additiva e nullable. Il gate god di Valhalla (e l'avvio impersonation) non deve fidarsi dello STATO
# dell'account (otp_enabled?) ma della SESSIONE: una sessione creata PRIMA che il god attivasse il 2FA
# non è mai passata dal secondo fattore e non deve entrare in Valhalla quando il 2FA viene attivato
# altrove. two_factor_verified_at presente = questa sessione ha completato il 2FA (o l'enrollment, che
# prova comunque il possesso del codice). nil = sessione senza secondo fattore.
class AddTwoFactorVerifiedAtToAccountsSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts_sessions, :two_factor_verified_at, :datetime
  end
end
