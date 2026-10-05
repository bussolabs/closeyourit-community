# frozen_string_literal: true

# CYRA-170 (A) — scadenza + idle-timeout delle sessioni web.
# Additiva: due colonne nullable su accounts_sessions.
# - expires_at    = scadenza ASSOLUTA della sessione (impostata al login = now + SESSION_ABSOLUTE_TTL).
# - last_active_at = ultima attività osservata (aggiornata throttled da resume_session).
#
# Backfill delle sessioni GIÀ vive: NON si invalidano di colpo al deploy (sarebbe un logout di massa).
# - expires_at si ancora al login (created_at + TTL): le sessioni molto vecchie scadono comunque per
#   scadenza assoluta al deploy (accettabile e coerente — hanno superato la finestra massima).
# - last_active_at = NOW() (istante del deploy), NON updated_at: le sessioni pre-esistenti NON
#   aggiornavano updated_at durante l'uso, quindi ancorare l'idle a updated_at renderebbe idle di colpo
#   ogni sessione attiva da oltre IDLE_TIMEOUT (7 giorni) = logout di massa (CYRA-170 FIX-9). Con NOW()
#   il timer di inattività riparte dal deploy: nessun logout di massa, l'idle vero riprende dal primo uso.
# L'intervallo è scritto LETTERALE (14 giorni) e non derivato da App::Constants: una migration storica
# deve restare stabile anche se in futuro la costante cambia.
class AddExpiryToAccountsSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :accounts_sessions, :expires_at, :datetime
    add_column :accounts_sessions, :last_active_at, :datetime

    say_with_time "backfill expires_at/last_active_at sulle sessioni esistenti" do
      execute(<<~SQL.squish)
        UPDATE accounts_sessions
        SET expires_at = created_at + INTERVAL '14 days',
            last_active_at = NOW()
        WHERE expires_at IS NULL
      SQL
    end

    add_index :accounts_sessions, :expires_at
  end

  def down
    remove_column :accounts_sessions, :expires_at
    remove_column :accounts_sessions, :last_active_at
  end
end
