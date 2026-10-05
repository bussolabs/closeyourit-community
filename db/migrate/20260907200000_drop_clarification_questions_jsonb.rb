# frozen_string_literal: true

# Via l'archivio vecchio delle domande di chiarimento (CYRA-784).
#
# Le domande vivono nelle righe di primo livello (`ticketing_questions`) da CYRA-779/780/781; il jsonb
# di `agents_clarifications` era il posto di prima, tenuto scritto in parallelo finché il contratto
# `agent-clarification/v1` e i suoi due lettori esterni non fossero passati all'endpoint. Ora sono
# passati, e due posti per lo stesso dato sono due posti che un giorno divergono.
#
# La tabella RESTA: è il registro dei GIRI (quale lavorazione, quale tentativo, quando ha ricevuto
# risposta, il testo storico servito verbatim), ed è ciò che `rounds[]` del contratto espone. Solo
# l'archivio delle domande se ne va.
#
# Il backfill è QUI e non nel rake (`questions:backfill`, che se ne va con questa migration): una
# passata manuale può essere stata dimenticata, e droppare la colonna la renderebbe irrecuperabile.
# Girare due volte non fa danno — le `NOT EXISTS` saltano ciò che è già a posto.
class DropClarificationQuestionsJsonb < ActiveRecord::Migration[8.1]
  # Un giro che l'INSERT non ha saputo portare non deve finire sotto il drop: dopo, il suo testo non
  # esiste più da nessuna parte. Meglio una migration che si ferma dicendo quali giri guardare che un
  # rilascio riuscito su un archivio più povero di prima.
  class ArchivioNonMigrato < StandardError; end

  def up
    backfill_questions
    backfill_answers
    ensure_nothing_left_behind!
    remove_column :agents_clarifications, :questions
  end

  # Ricostruibile: le domande tornano dalle righe, che da CYRA-781 sono la copia completa. Il testo
  # non si perde, cambia solo il posto da cui viene letto.
  def down
    add_column :agents_clarifications, :questions, :jsonb, default: [], null: false
    execute(<<~SQL.squish)
      UPDATE agents_clarifications AS cl
      SET questions = COALESCE(righe.bodies, '[]'::jsonb)
      FROM (
        SELECT round_id, jsonb_agg(body ORDER BY position, created_at) AS bodies
        FROM ticketing_questions
        WHERE round_id IS NOT NULL
        GROUP BY round_id
      ) AS righe
      WHERE righe.round_id = cl.id
    SQL
  end

  private

  # `author_id` NOT NULL sulle righe: l'autore è quello del commento che annunciava il giro, e dove il
  # commento non c'è più (o non c'è mai stato, prima di CYRA-215) è il segnalatore del ticket, l'unico
  # account certo di quell'organizzazione.
  #
  # `audience` 0 = internal, `origin` 1 = agent: i numeri e non i nomi, perché una migration è storia
  # e gli enum del modello possono essere rinumerati domani.
  def backfill_questions
    execute(<<~SQL.squish)
      INSERT INTO ticketing_questions
        (id, ticket_id, author_id, body, position, blocking, audience, origin, round_id,
         answered_at, created_at, updated_at)
      SELECT gen_random_uuid(), t.id, COALESCE(c.author_id, t.reporter_id), q.value, q.ordinality,
             true, 0, 1, cl.id, cl.answered_at, cl.created_at, cl.updated_at
      FROM agents_clarifications AS cl
      JOIN agents_workflows AS w ON w.id = cl.workflow_id
      JOIN ticketing_tickets AS t ON t.id = w.ticket_id
      LEFT JOIN ticketing_comments AS c ON c.id = cl.question_comment_id
      CROSS JOIN LATERAL jsonb_array_elements_text(cl.questions) WITH ORDINALITY AS q(value, ordinality)
      WHERE jsonb_typeof(cl.questions) = 'array'
        AND COALESCE(c.author_id, t.reporter_id) IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM ticketing_questions AS tq WHERE tq.round_id = cl.id
        )
    SQL
  end

  # `response_snapshot` resta sulla tabella e il contratto continua a servirlo verbatim, ma la scheda
  # Domande legge la RISPOSTA dalla riga: senza questo passo un giro storico comparirebbe come chiuso
  # e senza il testo di chi l'ha chiuso.
  #
  # `covers_round` true: lo snapshot è UNA risposta per un giro di massimo tre domande, e
  # l'attribuzione risposta↔domanda non è mai esistita. È lo stesso compromesso dichiarato di
  # Ticketing::Questions::BackfillLegacy, che questa migration sostituisce.
  def backfill_answers
    execute(<<~SQL.squish)
      WITH nuove AS (
        INSERT INTO ticketing_answers
          (id, question_id, author_id, body, covers_round, origin, created_at, updated_at)
        SELECT gen_random_uuid(), q.id, COALESCE(rc.author_id, t.reporter_id), cl.response_snapshot,
               true, 0, cl.answered_at, cl.answered_at
        FROM ticketing_questions AS q
        JOIN agents_clarifications AS cl ON cl.id = q.round_id
        JOIN agents_workflows AS w ON w.id = cl.workflow_id
        JOIN ticketing_tickets AS t ON t.id = w.ticket_id
        LEFT JOIN ticketing_comments AS rc ON rc.id = cl.response_comment_id
        WHERE cl.answered_at IS NOT NULL
          AND cl.response_snapshot IS NOT NULL
          AND q.answered_at IS NOT NULL
          AND COALESCE(rc.author_id, t.reporter_id) IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM ticketing_answers AS a WHERE a.question_id = q.id
          )
        RETURNING id, question_id
      )
      UPDATE ticketing_questions AS q
      SET resolved_answer_id = nuove.id
      FROM nuove
      WHERE nuove.question_id = q.id AND q.resolved_answer_id IS NULL
    SQL
  end

  # Le condizioni dell'INSERT possono lasciare indietro un giro: workflow o ticket spariti, nessun
  # autore nominabile, `questions` che non è un array. Sono casi che in produzione non dovrebbero
  # esistere — e proprio per questo, se esistono, vanno guardati da una persona invece di essere
  # cancellati da una migration.
  def ensure_nothing_left_behind!
    rimasti = select_values(<<~SQL.squish)
      SELECT cl.id::text
      FROM agents_clarifications AS cl
      WHERE jsonb_typeof(cl.questions) = 'array'
        AND jsonb_array_length(cl.questions) > 0
        AND NOT EXISTS (
          SELECT 1 FROM ticketing_questions AS tq WHERE tq.round_id = cl.id
        )
      ORDER BY cl.created_at
    SQL
    return if rimasti.empty?

    raise ArchivioNonMigrato,
          "#{rimasti.size} giri di chiarimento hanno domande nell'archivio e nessuna riga di primo " \
          "livello: droppare la colonna le perderebbe per sempre. Giri da guardare: " \
          "#{rimasti.first(20).join(', ')}#{'…' if rimasti.size > 20}"
  end
end
