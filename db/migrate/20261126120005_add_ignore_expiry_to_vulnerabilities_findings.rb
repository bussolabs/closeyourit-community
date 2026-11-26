# frozen_string_literal: true

# CYRA-1144 — ignorare una vulnerabilità diventa una decisione a tempo: fino a quando e chi l'ha presa.
# Le righe già ignorate restano senza scadenza (la pagina le mostra «senza scadenza»). FK nullify: se
# l'account viene rimosso la decisione resta, perde solo il nome di chi l'ha presa.
class AddIgnoreExpiryToVulnerabilitiesFindings < ActiveRecord::Migration[8.1]
  def change
    change_table :vulnerabilities_findings, bulk: true do |t|
      t.date :ignored_until, comment: "Giorno in cui la decisione di ignorare scade e la riga torna aperta"
      t.references :ignored_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }, index: true
    end
  end
end
