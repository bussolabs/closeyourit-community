# frozen_string_literal: true

# Sorgente "tickets" nelle preferenze di notifica personali: abilita le notifiche degli eventi
# ticket (creazione/assegnazione/cambio stato/milestone/commento/menzione). Default ON come le
# altre sorgenti (errors/uptime/performance) → chi non ha mai toccato le preferenze le riceve.
class AddTicketsEnabledToAlertingPreferences < ActiveRecord::Migration[8.1]
  def change
    add_column :alerting_preferences, :tickets_enabled, :boolean, default: true, null: false
  end
end
