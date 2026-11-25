# frozen_string_literal: true

# Measurements of a host currently above threshold, so the alert fires on crossing and on return (CYRA-1256).
class AddThresholdBreachesToServersHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :servers_hosts, :threshold_breaches, :jsonb, default: {}, null: false
  end
end
