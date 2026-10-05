# frozen_string_literal: true

# Performance issue detection (N+1, slow request, slow external HTTP): nuovo kind `performance_issue`
# su Metrics::*. `subtype` distingue le sotto-categorie dentro la corsia; `trace_id` correla il verdetto
# con log/errori della stessa richiesta (specchio di errors_events/logs_entries).
class AddPerformanceFieldsToMetrics < ActiveRecord::Migration[8.1]
  def change
    add_column :metrics_samples, :trace_id, :string
    add_column :metrics_samples, :subtype, :string
    add_column :metrics_groups, :subtype, :string

    add_index :metrics_samples, [ :project_id, :trace_id ]
    add_index :metrics_groups, [ :project_id, :kind, :subtype, :last_seen_at ],
              name: "index_metrics_groups_on_project_kind_subtype_last_seen"
  end
end
