# frozen_string_literal: true

# Snapshot immutabile della Guidance (references + procedures risolte da Guidance::Resolve) consegnata a
# un ticket nel momento della presa in carico (CYRA-76). Non congela il contesto alla CREAZIONE del ticket:
# lo fotografa al CLAIM, così un claim tardivo cattura la guidance CORRENTE. Una sola riga per ticket
# (indice unico su ticket_id): la creazione nel flusso di claim è idempotente e claim concorrenti non
# duplicano lo snapshot. organization_id è denormalizzato (radice di tenancy) per lo scoping d'audit,
# coerente con ticketing_events.
class CreateTicketingWorkContextSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_work_context_snapshots, id: :uuid do |t|
      t.timestamps

      # Uno snapshot per ticket: l'indice unico è ciò che rende il claim idempotente anche sotto
      # concorrenza (il secondo insert violerebbe il vincolo, non duplica).
      t.references :ticket, type: :uuid, null: false, index: { unique: true },
                            foreign_key: { to_table: :ticketing_tickets, on_delete: :cascade }
      t.references :organization, type: :uuid, null: false,
                                  foreign_key: { to_table: :organizations, on_delete: :cascade }
      # L'attore è il service account dell'host che prende in carico. Può sparire senza portarsi via
      # lo snapshot: il nome resta congelato in actor_name (come ticketing_reports.author_name).
      t.references :actor, type: :uuid, null: true,
                           foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.string   :actor_name
      # references + procedures risolte, nella stessa forma di Guidance::ResolutionSerializer.
      t.jsonb    :payload,         null: false, default: {}
      # Versione dello SCHEMA del payload (non versioni multiple per ticket): un cambio di forma del
      # payload la fa avanzare, così un lettore sa come interpretarlo.
      t.integer  :payload_version, null: false, default: 1
      # Firma SHA256 del payload canonico + versione: dimostra l'integrità del contesto consegnato.
      t.string   :digest,          null: false
      t.datetime :generated_at,    null: false
    end
  end
end
