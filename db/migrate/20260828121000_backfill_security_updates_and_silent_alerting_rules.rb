# frozen_string_literal: true

# CYRA-676 — i due avvisi nuovi (aggiornamenti di sicurezza in attesa, dati fermi) diventano default
# per le organizzazioni nuove via Alerting::Rules::InstallDefaults, ma quelle esistenti resterebbero
# scoperte: l'evento verrebbe generato e buttato via da Alerting::Evaluate. Stesso pattern del
# backfill di «Contenitori tornati su» (20260828090000).
class BackfillSecurityUpdatesAndSilentAlertingRules < ActiveRecord::Migration[8.1]
  # Interi grezzi append-only di Alerting::Rule: 46 = server_security_updates, 47 = server_silent.
  DEFAULTS = [
    { event_type: 46, name: "Aggiornamenti di sicurezza in attesa" },
    { event_type: 47, name: "Dati fermi" }
  ].freeze

  class Organization < ActiveRecord::Base
    self.table_name = "organizations"
  end

  class Rule < ActiveRecord::Base
    self.table_name = "alerting_rules"
  end

  def up
    Rule.reset_column_information
    now = Time.current
    org_ids = Organization.pluck(:id)

    DEFAULTS.each do |default|
      already = Rule.where(event_type: default[:event_type]).distinct.pluck(:organization_id).to_set
      rows = org_ids.reject { |id| already.include?(id) }.map do |organization_id|
        {
          organization_id: organization_id,
          event_type: default[:event_type],
          name: default[:name],
          enabled: true,
          throttle_seconds: 300,
          unhandled_only: false,
          created_at: now,
          updated_at: now
        }
      end
      Rule.insert_all(rows) if rows.any?
    end
  end

  def down
    # Le regole possono essere state modificate dall'utente: non è sicuro distinguerle e rimuoverle.
  end
end
