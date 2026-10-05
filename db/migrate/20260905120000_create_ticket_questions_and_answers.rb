# frozen_string_literal: true

# CYRA-779 — le domande su un ticket smettono di essere commenti.
#
# Fino a qui una domanda era una riga di servizio nella discussione più un record in
# `agents_clarifications`, e la risposta era il PRIMO commento umano arrivato dopo: l'aggancio era la
# vicinanza nel tempo, non l'identità. Bastava commentare d'altro per chiudere una domanda aperta e
# rimettere in coda una lavorazione — da cui la fila di guardie sparse (l'azione «chiedi» tolta
# quando c'è una domanda aperta, il gate sul ticket concluso, il marker dell'automazione).
#
# Il GIRO non sparisce e non diventa un intero su questa riga: resta `agents_clarifications`, che è
# dove vivono `response_snapshot` e `answered_at` — cioè il testo che il contratto
# `agent-clarification/v1` serve ai due repository esterni, byte per byte. Renderlo una colonna qui
# vorrebbe dire ricomporlo, e ricomporre uno storico è il modo di cambiarlo senza volerlo. Qui nasce
# soltanto ciò che il giro non sapeva rappresentare: la domanda singola, la sua risposta, e la
# domanda posta da una persona — che di giro non ne ha nessuno.
#
# Non la usa ancora nessuno: questa migration è rilasciabile da sola e non cambia niente di ciò che
# si vede.
class CreateTicketQuestionsAndAnswers < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_questions, id: :uuid do |t|
      t.timestamps

      t.references :ticket, type: :uuid, null: false,
                            foreign_key: { to_table: :ticketing_tickets, on_delete: :cascade }
      t.references :author, type: :uuid, null: false,
                            foreign_key: { to_table: :accounts }
      t.text :body, null: false

      # Il giro di chiarimenti che l'ha generata, quando esiste. Nullable perché la domanda di una
      # PERSONA non appartiene a nessun giro: è la ragione per cui il giro non poteva restare l'unico
      # archivio. `nullify` e non `cascade`: domande e risposte sono la memoria di uno scambio fra
      # persone e restano leggibili anche quando la lavorazione che le ha generate non c'è più,
      # esattamente come restano i commenti.
      #
      # La colonna sta qui, ma la RELAZIONE la dichiara il lato agenti (CYRA-746: è il dominio degli
      # agenti a conoscere il ticket, mai il contrario).
      t.references :round, type: :uuid, null: true,
                           foreign_key: { to_table: :agents_clarifications, on_delete: :nullify }

      # Solo una domanda BLOCCANTE ferma il ticket. Il default è il caso normale: chiedere non deve
      # fermare il lavoro di nessuno finché chi chiede non dice che senza risposta non si prosegue.
      t.boolean :blocking, null: false, default: false

      # CHI la vede. `internal` = chi può modificare il ticket; `shared` = chiunque veda il ticket,
      # cliente compreso. Il default è il riservato: una domanda che sfugge al cliente per svista è un
      # danno, una domanda interna che andava condivisa è un click.
      t.integer :audience, null: false, default: 0

      # CHI l'ha posta, fotografato al momento. Ricavabile da `author.service?`, ma un service account
      # riclassificato domani non deve riscrivere la storia di ieri — è la stessa ragione per cui la
      # cronologia si porta dietro il nome dell'attore invece di andarselo a rileggere.
      t.integer :origin, null: false, default: 0

      # Posizione dentro il giro (1..3) e nella pagina.
      t.integer :position, null: false, default: 0

      # L'AUTORITÀ sul «ha risposto» sta qui, non nella presenza di una risposta. È la lezione di
      # CYRA-219 riportata: una risposta si può cancellare, e se il fatto vivesse nella riga della
      # risposta cancellarla riaprirebbe una domanda che qualcuno aveva chiuso.
      t.datetime :answered_at
      t.datetime :closed_at
      t.references :closed_by, type: :uuid, null: true,
                               foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.index %i[ticket_id created_at]
      t.index %i[round_id position]
      # L'indice del BLOCCO: è la domanda che la coda degli agenti fa a ogni giro, e riguarda una
      # manciata di righe su tutte quelle che la tabella conterrà. Parziale, quindi, e sulle sole
      # bloccanti — le altre non trattengono niente e non hanno motivo di stare in un indice caldo.
      t.index :ticket_id, where: "blocking AND answered_at IS NULL AND closed_at IS NULL",
                          name: "index_ticketing_questions_blocking_open"
    end

    create_table :ticketing_answers, id: :uuid do |t|
      t.timestamps

      t.references :question, type: :uuid, null: false,
                              foreign_key: { to_table: :ticketing_questions, on_delete: :cascade }
      t.references :author, type: :uuid, null: false,
                            foreign_key: { to_table: :accounts }
      t.text :body, null: false
      t.integer :origin, null: false, default: 0

      # Risposta che copre l'INTERO giro, non questa sola domanda. Serve allo storico: fino a oggi la
      # risposta era una per giro di massimo tre domande, e l'attribuzione risposta↔domanda non è mai
      # esistita. Senza questa colonna la pagina scriverebbe «risposta alla domanda 1», che è una
      # bugia; con questa scrive «risposta all'intero giro», che è quello che è successo.
      t.boolean :covers_round, null: false, default: false

      t.index %i[question_id created_at]
    end

    # Quale delle risposte è QUELLA che ha chiuso la domanda. Aggiunta dopo, perché le due tabelle si
    # nominano a vicenda e una delle due deve esistere per prima.
    add_reference :ticketing_questions, :resolved_answer, type: :uuid, null: true,
                                                          foreign_key: { to_table: :ticketing_answers,
                                                                         on_delete: :nullify }
  end
end
