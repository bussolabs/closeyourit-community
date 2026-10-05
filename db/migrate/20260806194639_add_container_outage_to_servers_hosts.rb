# frozen_string_literal: true

class AddContainerOutageToServersHosts < ActiveRecord::Migration[8.1]
  def change
    # Esito dell'ultima transizione dei container rilevata dall'ingest (CYRA-248): stato corrente, non
    # storia, come failed_services/smart_data. `{}` = sano; `{"names" => [...]}` = quei container sono
    # spariti dall'ultimo set noto (Docker su); `{"engine_down" => true}` = tutti spariti insieme /
    # motore non interrogabile. Alerting::Content lo legge per comporre il body di server_container_down.
    add_column :servers_hosts, :container_outage, :jsonb, null: false, default: {}
  end
end
