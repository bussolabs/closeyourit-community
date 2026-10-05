# frozen_string_literal: true

class CreateSettingsGlobals < ActiveRecord::Migration[8.1]
  def change
    # Riga singola di configurazione globale di sistema (god). Vedi Settings::Global.instance.
    create_table :settings_global, id: :uuid do |t|
      t.timestamps

      t.integer :logs_retention_days   # retention di default dei log (giorni); nil → App::Constants
    end
  end
end
