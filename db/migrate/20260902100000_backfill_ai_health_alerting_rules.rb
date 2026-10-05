# frozen_string_literal: true

# CYRA-712 — regole default degli avvisi sull'intelligenza artificiale per le organizzazioni che
# esistono già (stesso pattern dei backfill 20260828090000, 20260828121000 e 20260828142000: le org
# nuove le ricevono da Alerting::Rules::InstallDefaults, quelle esistenti resterebbero scoperte e
# Alerting::Evaluate genererebbe l'evento per poi buttarlo via — cioè il silenzio che questa
# lavorazione esiste per rompere, lasciato intatto proprio dove il prodotto è già in funzione).
class BackfillAiHealthAlertingRules < ActiveRecord::Migration[8.1]
  # Interi grezzi append-only di Alerting::Rule: 49 = ai_unavailable, 50 = ai_available.
  # Throttle a un'ora sulla caduta (il controllo gira ogni quarto d'ora e una chiave scaduta resta
  # scaduta: senza, quattro avvisi l'ora per lo stesso guasto), default sul rientro, che è unico.
  DEFAULTS = [
    { event_type: 49, name: "Intelligenza artificiale non raggiungibile", throttle_seconds: 3600 },
    { event_type: 50, name: "Intelligenza artificiale ripristinata", throttle_seconds: 300 }
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
    organization_ids = Organization.pluck(:id)

    DEFAULTS.each do |default|
      already = Rule.where(event_type: default[:event_type]).distinct.pluck(:organization_id).to_set
      rows = organization_ids.reject { |id| already.include?(id) }.map do |organization_id|
        { organization_id: organization_id, event_type: default[:event_type], name: default[:name],
          enabled: true, throttle_seconds: default[:throttle_seconds], unhandled_only: false,
          created_at: now, updated_at: now }
      end
      Rule.insert_all(rows) if rows.any?
    end
  end

  def down
    # Le regole possono essere state modificate dall'utente: non è sicuro distinguerle e rimuoverle.
  end
end
