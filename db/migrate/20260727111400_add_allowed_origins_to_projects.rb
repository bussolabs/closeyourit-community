# frozen_string_literal: true

# CYRA-109 — Origin allowlist per-progetto per il public ingest (DSN public key non-segreta).
# Difesa browser AGGIUNTIVA (mai autenticazione): se non vuota, le richieste browser (con header
# Origin) da un'origine non elencata vengono rifiutate; le richieste senza Origin (client non-browser)
# e la lista vuota non vengono mai bloccate. Enforce nel gateway ingest, non via CORS.
class AddAllowedOriginsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :allowed_origins, :jsonb, default: [], null: false
  end
end
