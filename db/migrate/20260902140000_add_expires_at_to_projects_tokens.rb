# frozen_string_literal: true

# CYRA-716 — scadenza delle credenziali di ingest di progetto. NULL = nessuna scadenza: i token
# già emessi (e gli SDK in produzione che li usano) restano validi finché non li si revoca o non
# gli si mette una data a mano. Una scadenza retroattiva d'ufficio spegnerebbe l'ingest di chi non
# ha fatto niente di sbagliato.
class AddExpiresAtToProjectsTokens < ActiveRecord::Migration[8.1]
  def change
    add_column :projects_tokens, :expires_at, :datetime
    # Il giro giornaliero del promemoria cerca per sola scadenza, org-wide: senza indice legge
    # l'intera tabella dei token ogni notte.
    add_index :projects_tokens, :expires_at
  end
end
