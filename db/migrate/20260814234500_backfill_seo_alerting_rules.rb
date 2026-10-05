# frozen_string_literal: true

class BackfillSeoAlertingRules < ActiveRecord::Migration[8.1]
  # CYRA-528: `seo_issue_new` (43) nasce dopo tutte le organizzazioni esistenti. Le regole di
  # alerting si installano solo al provisioning (Alerting::Rules::InstallDefaults), quindi nessuna
  # org ne avrebbe una: il giro troverebbe il rilievo, lo scriverebbe, e Alerting::Evaluate — non
  # trovando regole — non avviserebbe nessuno. Il silenzio esattamente dove serviva la voce.
  #
  # Evento PROJECT-SCOPED (come gli errori): copre tutta l'org solo se nasce org-wide, cioè con
  # project_id ed environment_id nulli. Una regola legata a un progetto lascerebbe scoperti gli altri.
  #
  # L'intero resta grezzo perché la migrazione deve restare valida anche se l'enum evolve.
  # Idempotente: conta solo le regole org-wide già presenti.
  EVENT_TYPE = 43
  NAME = "Nuovo rilievo SEO"

  class Organization < ActiveRecord::Base
    self.table_name = "organizations"
  end

  class Rule < ActiveRecord::Base
    self.table_name = "alerting_rules"
  end

  def up
    Rule.reset_column_information
    now = Time.current

    covered = Rule.where(event_type: EVENT_TYPE, project_id: nil, environment_id: nil)
                  .distinct.pluck(:organization_id).to_set

    rows = Organization.pluck(:id).reject { |id| covered.include?(id) }.map do |organization_id|
      {
        organization_id: organization_id, event_type: EVENT_TYPE, name: NAME,
        enabled: true, throttle_seconds: 300, unhandled_only: false,
        created_at: now, updated_at: now
      }
    end

    Rule.insert_all(rows) if rows.any?
  end

  def down
    Rule.where(event_type: EVENT_TYPE, name: NAME).delete_all
  end
end
