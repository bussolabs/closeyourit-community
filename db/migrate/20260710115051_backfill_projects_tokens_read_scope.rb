# frozen_string_literal: true

# CYRA-37 — retro-compat: i token emessi prima dell'enforcement degli scope avevano di fatto piena
# potenza (ingest + read), perché `scopes` era persistito ma MAI applicato (token_authentication.rb).
# Ora che require_scope!(:read) è attivo, concediamo 'read' a chi non ce l'ha così NON perde la
# lettura. Op idempotente in SQL sul jsonb (@> = contains, || = append array).
# Vedi decisions/2026-07-09-cyi-token-server-only.
class BackfillProjectsTokensReadScope < ActiveRecord::Migration[8.1]
  def up
    execute(<<~SQL.squish)
      UPDATE projects_tokens
      SET scopes = scopes || '["read"]'::jsonb
      WHERE NOT (scopes @> '["read"]'::jsonb)
    SQL
  end

  def down
    # Irreversibile per design: non distinguiamo i token nati con 'read' da quelli backfillati qui.
  end
end
