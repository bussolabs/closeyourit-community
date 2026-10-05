# frozen_string_literal: true

# CYRA-620 — la prova che il codice approvato è davvero atterrato sulla linea principale.
#
# Finora il lavoro andava avanti perché la macchina scriveva «fatto». Se l'ultimo passaggio non
# riusciva — spedizione rifiutata, connessione caduta, copia di lavoro vecchia — nessuno se ne
# accorgeva: il passo dopo partiva lo stesso, e in produzione poteva uscire un codice diverso da
# quello approvato, o nessuno.
#
# Le due cose restano SEPARATE e con due colonne diverse: «la macchina ha consegnato»
# (`closer_staging_completed_at`) e «il sistema ha visto» (`closer_staging_verified_at`). Tenerle
# insieme è ciò che permette a un rilascio di prova già fatto di essere rimesso in coda e ripetuto.
class AddStagingProofToAgentsWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_workflows, :closer_staging_verified_at, :datetime
    add_column :agents_workflows, :closer_staging_next_check_at, :datetime
    add_column :agents_workflows, :closer_staging_checks_count, :integer, default: 0, null: false
    add_column :agents_workflows, :closer_staging_last_error_code, :string

    # Indice PARZIALE sulle sole righe che aspettano davvero un controllo: consegnate e non ancora
    # verificate. Su tutta la tabella sarebbe un indice che il giro periodico non usa mai per intero.
    add_index :agents_workflows, :closer_staging_next_check_at,
              where: "closer_staging_completed_at IS NOT NULL AND closer_staging_verified_at IS NULL",
              name: "index_agents_workflows_staging_proof_due"

    add_check_constraint :agents_workflows, "closer_staging_checks_count >= 0",
                         name: "agents_workflows_staging_checks_count_non_negative"
  end
end
