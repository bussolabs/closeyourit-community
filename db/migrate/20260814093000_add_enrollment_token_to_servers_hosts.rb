# frozen_string_literal: true

# CYRA-469 — con quale codice di accesso si è registrata una macchina. Serve a dire, sulla pagina
# dei codici, quante macchine sono collegate a ciascuno e a mostrarle: prima non lo sapeva nessuno.
# Nullable per costruzione: gli host già registrati prima di questa colonna non hanno un codice
# attribuibile (il dato storico non esiste, non lo si inventa) e restano legati solo dai nuovi
# enrollment. on_delete: :nullify → cancellare un codice non porta via con sé le macchine.
class AddEnrollmentTokenToServersHosts < ActiveRecord::Migration[8.1]
  def change
    add_reference :servers_hosts, :enrollment_token, type: :uuid, null: true, index: true
    add_foreign_key :servers_hosts, :servers_enrollment_tokens,
                    column: :enrollment_token_id, on_delete: :nullify
  end
end
