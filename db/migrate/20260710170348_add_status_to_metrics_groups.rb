# frozen_string_literal: true

# CYRA-45: stato di triage dei gruppi-metrica, speculare a errors_groups.status. Abilita il triage
# (resolve/ignore/reopen) e il triage bulk anche per query/metodi lenti: il rumore da un deploy
# (feature flag rotta → N query lente) si silenzia in massa come per gli errori. default 0 = unresolved,
# così i gruppi esistenti restano aperti; NOT NULL come errors_groups. Indice gemello per i filtri di stato.
class AddStatusToMetricsGroups < ActiveRecord::Migration[8.1]
  def change
    add_column :metrics_groups, :status, :integer, default: 0, null: false
    add_index :metrics_groups, %i[project_id status last_seen_at],
              name: "index_metrics_groups_on_project_id_and_status_and_last_seen_at"
  end
end
