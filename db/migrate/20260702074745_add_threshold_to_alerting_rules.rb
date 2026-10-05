class AddThresholdToAlertingRules < ActiveRecord::Migration[8.1]
  def change
    # Soglia generica per gli event_type server_* (percentuale per cpu/mem/disk, °C per temp).
    # Colonna NUOVA: threshold_ms resta com'è (semantica ms di metric_threshold, esposta da
    # serializer + CLI in produzione — rinominarla romperebbe il contratto).
    add_column :alerting_rules, :threshold, :decimal
  end
end
