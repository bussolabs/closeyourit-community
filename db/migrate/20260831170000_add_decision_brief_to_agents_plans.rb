# frozen_string_literal: true

# CYRA-702 — il brief decisionale del piano: poche frasi in linguaggio semplice scritte dal
# planner per chi approva dalla coda. Opzionale per contratto: i planner non aggiornati
# consegnano senza, e la card ripiega sulla sintesi tecnica.
class AddDecisionBriefToAgentsPlans < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_plans, :decision_brief, :text
  end
end
