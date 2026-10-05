# frozen_string_literal: true

# CYRA-519 — una regola di avviso valeva per tutta la flotta: se su una macchina produceva falsi
# allarmi, l'unica scelta era spegnerla ovunque e perdere il segnale anche dove serviva. Qui vive
# l'eccezione per-macchina: la regola resta accesa, ma su QUELLA macchina tace.
class CreateAlertingRuleHostExclusions < ActiveRecord::Migration[8.1]
  def change
    create_table :alerting_rule_host_exclusions, id: :uuid do |t|
      t.references :rule, null: false, type: :uuid, foreign_key: { to_table: :alerting_rules }
      t.references :host, null: false, type: :uuid, foreign_key: { to_table: :servers_hosts }
      t.timestamps
    end

    # Una sola eccezione per coppia: escludere due volte la stessa macchina non vuol dire niente.
    add_index :alerting_rule_host_exclusions, %i[rule_id host_id], unique: true,
              name: "idx_alerting_rule_host_exclusions_unique"
  end
end
