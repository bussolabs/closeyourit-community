# frozen_string_literal: true

# CYRA-624 — il ticket diventava «Fatto» nell'istante in cui la macchina diceva di aver messo
# l'etichetta della versione. In quel momento non era ancora stato rilasciato niente: il rilascio
# parte dopo, e può andare male un minuto dopo. Il ticket restava «Fatto» lo stesso.
#
# Qui nasce la riga su cui il sistema tiene il conto di ciò che sta guardando: cosa si aspetta di
# vedere (congelato prima del rilascio), cosa ha visto, quando torna a guardare e perché l'ultima
# volta non ci è riuscito.
class CreateAgentsWorkflowProbes < ActiveRecord::Migration[8.1]
  def change
    create_table :agents_workflow_probes, id: :uuid do |t|
      t.references :workflow, null: false, type: :uuid,
                              foreign_key: { to_table: :agents_workflows }, index: false
      t.string :kind, null: false
      # Congelato all'aggancio: la versione e il codice sigillato sono quelli decisi PRIMA che il
      # rilascio partisse. Ricavarli dall'etichetta osservata vorrebbe dire chiedere alla cosa
      # osservata di dire se se stessa è giusta.
      t.jsonb :expected, null: false, default: {}
      t.jsonb :evidence, null: false, default: {}
      t.datetime :bound_at, null: false
      t.datetime :closed_at
      t.datetime :next_check_at
      t.string :last_error_code
      t.integer :checks_count, null: false, default: 0
      t.timestamps
    end

    # Una prova viva per lavorazione: due righe aperte vorrebbero dire due verità sullo stesso
    # rilascio, e la seconda arriverebbe da un aggancio ripetuto — cioè da un errore.
    add_index :agents_workflow_probes, :workflow_id, unique: true, where: "closed_at IS NULL",
              name: "index_agents_workflow_probes_live"
    add_index :agents_workflow_probes, :next_check_at, where: "closed_at IS NULL",
              name: "index_agents_workflow_probes_due"
    add_check_constraint :agents_workflow_probes, "jsonb_typeof(expected) = 'object'",
                         name: "agents_workflow_probes_expected_object"
    add_check_constraint :agents_workflow_probes, "checks_count >= 0",
                         name: "agents_workflow_probes_checks_non_negative"
  end
end
