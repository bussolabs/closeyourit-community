# frozen_string_literal: true

# Gate umano prima della produzione (CYRA-504). closer_production diventava reclamabile appena
# closer_staging_completed_at era scritto: l'unico passo irreversibile della catena non aveva
# approvazione. Le colonne sono gemelle di autopilot_approved_at/_by e nascono nulle — le
# lavorazioni già oltre lo staging si fermano in attesa, quelle già reclamate proseguono.
class AddCloserProductionApprovalToAgentsWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_workflows, :closer_production_approved_at, :datetime
    # on_delete: :nullify come tutte le altre FK verso accounts di questa tabella: cancellare la
    # persona che ha autorizzato non deve portarsi via la lavorazione (né farla esplodere).
    add_reference :agents_workflows, :closer_production_approved_by, type: :uuid, null: true,
                                                                     foreign_key: { to_table: :accounts,
                                                                                    on_delete: :nullify },
                                                                     index: { name: "idx_agents_workflows_closer_production_approved_by" }
  end
end
