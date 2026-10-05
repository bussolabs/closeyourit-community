# frozen_string_literal: true

# CYRA-621 — il numero di versione lo assegna il SERVER, una volta sola, prima che il lavoro parta.
#
# Finora lo sceglieva la macchina, da sola, pochi secondi prima di pubblicare: le istruzioni le
# dicevano «guarda l'ultimo numero e le novità, poi decidi tu quale cifra cambiare». Nessuno
# controllava quella scelta, né prima né dopo. Tre conseguenze: due lavorazioni dello stesso progetto
# che rilasciano insieme sceglievano lo stesso numero e la seconda veniva respinta; la versione di
# prova e quella definitiva venivano numerate da due sessioni diverse senza garanzia che tornassero;
# e un errore di valutazione faceva raccontare al numero una cosa falsa, senza modo di accorgersene.
#
# I due indici unici sono il cuore: uno per lavorazione+fase (una fase, un numero, per sempre) e uno
# per repository+versione (lo stesso nome non si assegna due volte, e la corsa fra due lavorazioni la
# perde il database invece di GitHub a pubblicazione avvenuta).
class CreateAgentsReleaseAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :agents_release_assignments, id: :uuid do |t|
      t.references :workflow, null: false, type: :uuid, foreign_key: { to_table: :agents_workflows }
      t.references :github_repository, null: false, type: :uuid, foreign_key: { to_table: :github_repositories }
      t.string :execution_phase, null: false
      t.string :version, null: false
      # `sha` è il punto esatto di codice da pubblicare, e vale solo per la versione definitiva: sulla
      # prova non c'è ancora niente di atterrato da nominare.
      t.string :sha
      # Da quale numero si è partiti: senza, fra un mese non c'è modo di rifare il conto.
      t.string :baseline_tag

      t.timestamps
    end

    add_index :agents_release_assignments, %i[workflow_id execution_phase], unique: true,
              name: "index_agents_release_assignments_identity"
    add_index :agents_release_assignments, %i[github_repository_id version], unique: true,
              name: "index_agents_release_assignments_version"

    add_check_constraint :agents_release_assignments,
                         "execution_phase IN ('closer_staging', 'closer_production')",
                         name: "agents_release_assignments_phase_valida"
    add_check_constraint :agents_release_assignments, "sha IS NULL OR sha ~ '^[0-9a-f]{40}$'",
                         name: "agents_release_assignments_sha_shape"
  end
end
