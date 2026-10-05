# frozen_string_literal: true

# CYRA-106 — l'invio dei secret verso GitHub gira in un job fire-and-forget: un esito fallito tornava
# come Result.err, il job non sollevava e la pagina restava identica a quella di un invio riuscito.
# Nel caso reale il silenzio è costato 9 giorni. Qui si persiste l'esito dell'ULTIMO tentativo —
# quando, com'è andato e, se è andato male, il codice con i dettagli strutturati (slot, file, riga,
# nomi) — così la scheda GitHub del progetto può dirlo invece di tacere.
#
# `last_sync_status` nullable: un repo che non ha mai provato non ha un esito, e "mai provato" non è
# "riuscito". `last_sync_error` è vuoto quando l'ultimo invio è riuscito: l'errore vecchio non
# sopravvive al successivo successo.
class AddLastSyncOutcomeToGithubRepositories < ActiveRecord::Migration[8.1]
  def change
    add_column :github_repositories, :last_sync_at, :datetime
    add_column :github_repositories, :last_sync_status, :string
    add_column :github_repositories, :last_sync_error, :jsonb, default: {}, null: false
  end
end
