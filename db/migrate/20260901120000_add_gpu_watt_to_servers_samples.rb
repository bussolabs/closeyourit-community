# frozen_string_literal: true

# CYRA-703 — i watt assorbiti dalla scheda grafica, accanto alla percentuale d'uso che c'era già.
# Colonna e non payload: la serie storica del grafico si legge con un AVG su colonna indicizzata,
# mentre nel jsonb le chiavi delle GPU sono dinamiche ("0", "1") e il massimo fra più schede
# richiederebbe un LATERAL che moltiplica le righe per il numero di GPU.
class AddGpuWattToServersSamples < ActiveRecord::Migration[8.1]
  def change
    add_column :servers_samples, :gpu_watt, :decimal, precision: 8, scale: 2
  end
end
