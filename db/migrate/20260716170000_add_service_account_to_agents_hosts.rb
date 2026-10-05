# frozen_string_literal: true

# B.1 — Identità dell'host: ogni Agents::Host ha 1 solo service account (l'agente che opera). FK nullable durante
# la transizione (host storici senza identità restano validi; backfill/registrazione la popolano), indice UNIQUE
# per garantire l'invariante 1 host ↔ 1 service account. on_delete :nullify: il service account non si distrugge
# (audit-safe, coerente con certified_by e Accounts::Service::Retire).
class AddServiceAccountToAgentsHosts < ActiveRecord::Migration[8.1]
  def change
    change_table :agents_hosts, bulk: true do |t|
      t.references :service_account, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify },
                   index: { unique: true }
    end
  end
end
