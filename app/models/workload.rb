# frozen_string_literal: true

module Workload
  # Dominio del carico di lavoro NON-dev del team (fiere, materiale grafico, meeting, chiamate),
  # parallelo e distinto da Ticketing:: (lavoro tech). Vive per-team: una action appartiene a UN
  # Teams::Team e la visibilità = appartenenza al team (vedi Workload::Action.visible_to).
  def self.table_name_prefix = "workload_"
end
