# frozen_string_literal: true

# CYRA-184 — Gate di eleggibilità agenti. Un ticket raggiunge la coda degli agenti autonomi SOLO se
# marcato `allowed`; il verdetto lo produce Gemini leggendo corpo e allegati, e un umano può
# ribaltarlo in entrambi i sensi.
#
# `agent_eligibility` nasce a 0 (`pending`) e questo è il cuore della sicurezza: ogni riga esistente,
# ogni import, ogni seed e ogni futuro percorso di creazione che ignori la feature parte NON lavorabile.
# Il fail-closed non è una scrittura difensiva a runtime, è il default della colonna.
#
# `agent_eligibility_source` è la stickiness dell'override umano, e NON è derivabile da
# "decided_by_id presente": quella FK è on_delete: :nullify, quindi cancellare l'account che ha
# deciso riaprirebbe SILENZIOSAMENTE il ticket alla rivalutazione automatica. La decisione umana non
# deve dipendere dalla sopravvivenza di una riga `accounts`.
class AddAgentEligibilityToTicketingTickets < ActiveRecord::Migration[8.1]
  def change
    add_column :ticketing_tickets, :agent_eligibility, :integer, null: false, default: 0
    add_column :ticketing_tickets, :agent_eligibility_source, :integer, null: false, default: 0
    # text e non string: la motivazione è 1-3 frasi di Gemini o testo libero umano, varchar(255)
    # produrrebbe troncamenti silenziosi o 500.
    add_column :ticketing_tickets, :agent_eligibility_reason, :text
    # Gemello di embedding_checksum: SHA256 del corpo + fingerprint allegati + versione del prompt.
    add_column :ticketing_tickets, :agent_eligibility_checksum, :string
    # Due timestamp con UN SOLO scrittore ciascuno: evaluated_at lo scrive solo il percorso
    # automatico, decided_at solo l'override umano. Un timestamp unico costringerebbe a leggere
    # `source` per sapere che cosa si sta guardando.
    add_column :ticketing_tickets, :agent_eligibility_evaluated_at, :datetime
    add_column :ticketing_tickets, :agent_eligibility_decided_at, :datetime
    add_reference :ticketing_tickets, :agent_eligibility_decided_by, type: :uuid, null: true,
                  index: { name: "index_ticketing_tickets_on_agent_eligibility_decided_by" },
                  foreign_key: { to_table: :accounts, on_delete: :nullify }

    # Composito e non secco sulla singola colonna a 3 valori: serve entrambi i consumatori reali —
    # la query di Agents::TicketQueues::Next (sempre project-scoped) e il filtro della lista ticket.
    add_index :ticketing_tickets, [ :project_id, :agent_eligibility ],
              name: "index_ticketing_tickets_on_project_id_and_agent_eligibility"
  end
end
