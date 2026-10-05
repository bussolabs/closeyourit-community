# frozen_string_literal: true

# CYRA-679 — memoria dell'avviso di previsione disco: {"days" => stima corrente, "alerted_at" => ...}.
# L'avviso parte solo quando la stima ENTRA sotto la soglia (isteresi: si riarma quando risale oltre
# il margine), non a ogni giro del job giornaliero.
class AddDiskForecastStateToServersHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :servers_hosts, :disk_forecast_state, :jsonb, default: {}, null: false
  end
end
