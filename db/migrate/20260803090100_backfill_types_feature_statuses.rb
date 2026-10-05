# frozen_string_literal: true

# Gli stati della matrice funzionalità (CYRA-256) nascono da Types::InstallDefaults, che gira al
# provisioning di una nuova org: senza questo backfill le org GIÀ esistenti resterebbero senza
# nessuno stato e la matrice sarebbe inutilizzabile (nessuna cella salvabile). Idempotente.
# I valori di `category` restano interi grezzi così la migrazione è autoconsistente se l'enum del
# modello evolve (stesso criterio di BackfillUptimeAlertingRules).
class BackfillTypesFeatureStatuses < ActiveRecord::Migration[8.1]
  DEFAULTS = [
    { code: "unplanned",      label: "Not planned",    color: "gray",    position: 0, category: 0 },
    { code: "planned",        label: "Planned",        color: "sky",     position: 1, category: 1 },
    { code: "in_development", label: "In development", color: "indigo",  position: 2, category: 2 },
    { code: "available",      label: "Available",      color: "emerald", position: 3, category: 3 },
    { code: "deprecated",     label: "Deprecated",     color: "amber",   position: 4, category: 4 },
    { code: "not_applicable", label: "Not applicable", color: "gray",    position: 5, category: 5 }
  ].freeze

  class Organization < ActiveRecord::Base
    self.table_name = "organizations"
  end

  class FeatureStatus < ActiveRecord::Base
    self.table_name = "types_feature_statuses"
  end

  def up
    FeatureStatus.reset_column_information
    now = Time.current

    rows = Organization.pluck(:id).flat_map do |organization_id|
      DEFAULTS.map do |attrs|
        attrs.merge(organization_id: organization_id, active: true, created_at: now, updated_at: now)
      end
    end
    return if rows.empty?

    # ON CONFLICT DO NOTHING sull'indice unico [organization_id, code]: una sola query, ripetibile.
    FeatureStatus.insert_all(rows, unique_by: %i[organization_id code])
  end

  def down
    # Non distinguiamo gli stati seminati da quelli personalizzati nel frattempo → non ripristinabile.
  end
end
