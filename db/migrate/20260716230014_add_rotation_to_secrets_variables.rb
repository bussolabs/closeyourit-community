# frozen_string_literal: true

# Rotazione "morbida" dei secret (CYRA-138, Fase 4 pezzo A1): additiva, nessun dato esistente rotto.
# `rotation_interval_days` (nil default) = policy opt-in "ruota ogni N giorni"; `rotated_at` = ultima
# volta che il VALORE è cambiato (fonte: Secrets::Variables::Set). La scadenza calcolata da queste due
# colonne è solo un avviso — Secrets::Bundle e il flusso di lettura restano invariati.
class AddRotationToSecretsVariables < ActiveRecord::Migration[8.1]
  def up
    change_table :secrets_variables, bulk: true do |t|
      t.integer :rotation_interval_days, null: true
      t.datetime :rotated_at, null: true
    end

    # Backfill: le righe esistenti non sono mai passate da Secrets::Variables::Set con la colonna
    # nuova. rotated_at = created_at è la miglior approssimazione ragionevole di "ultima volta che il
    # valore è cambiato" per una riga già in DB — così una policy di rotazione aggiunta in futuro su un
    # secret esistente calcola subito una scadenza sensata invece di restare :none per rotated_at nil.
    say_with_time "backfill secrets_variables.rotated_at" do
      execute("UPDATE secrets_variables SET rotated_at = created_at WHERE rotated_at IS NULL")
    end
  end

  def down
    change_table :secrets_variables, bulk: true do |t|
      t.remove :rotation_interval_days
      t.remove :rotated_at
    end
  end
end
