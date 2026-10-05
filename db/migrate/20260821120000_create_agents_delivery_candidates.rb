# frozen_string_literal: true

# CYRA-604 — il registro di cosa il sistema ha guardato.
#
# Oggi la macchina dice «ho fatto» e il lavoro compare fra le cose da revisionare: nessuno ha
# guardato niente, il sistema si e' fidato di una frase. Perche' possa guardare davvero serve prima
# un posto dove scrivere cosa ha guardato. Questa tabella e' quel posto, e resta inerte finche' non
# arriva chi ci scrive: nessuna pagina cambia, nessun pulsante si sposta.
#
# Tre cose dipendono da com'e' fatta, e sono tutte e tre nel database perche' il modello non basta.
class CreateAgentsDeliveryCandidates < ActiveRecord::Migration[8.1]
  # Gli stati per cui ha senso tornare a guardare: non si e' ancora guardato, i controlli stanno
  # ancora girando, oppure non si e' riusciti a guardare. Gli altri sono definitivi.
  RITENTABILI = %w[pending checks_running unreachable].freeze
  RITENTABILI_SQL = "state IN (0, 4, 5)"
  # I tre esiti che valgono come «ho guardato»: passa, non c'e' nessun controllo configurato, fallisce.
  VERIFICATI_SQL = "state IN (1, 2, 3)"

  def change
    create_table :agents_delivery_candidates, id: :uuid do |t|
      t.references :workflow, type: :uuid, null: false, foreign_key: { to_table: :agents_workflows }
      t.references :attempt, type: :uuid, null: false, foreign_key: { to_table: :agents_attempts }

      # NULLABLE di proposito: la consegna porta solo l'indirizzo della proposta, e il nome del
      # progetto va risolto. Se non si risolve dentro l'organizzazione della lavorazione la riga
      # nasce `rejected` col motivo, e questa colonna resta vuota — mai una chiave verso un'altra
      # organizzazione, che sarebbe la cosa peggiore che possa succedere qui.
      t.references :repository, type: :uuid, null: true, foreign_key: { to_table: :github_repositories }
      # Il nome OSSERVATO nella consegna, sempre presente anche quando non si aggancia a niente:
      # senza, una riga rifiutata non direbbe nemmeno di cosa parlava.
      t.string :repository_full_name, null: false
      t.integer :number, null: false

      # NULLABLE: la riga nasce PRIMA di sapere quale codice c'e' dentro la proposta. Il codice
      # esatto si scopre solo andando a guardare, e si scrive dopo. Se fossero obbligatori qui, il
      # passo che registra la consegna non potrebbe nemmeno cominciare e la catena si fermerebbe
      # alla prima riga.
      t.string :head_sha, null: true
      t.string :base_ref, null: true

      t.integer :state, null: false, default: 0

      # NULL e `[]` sono due cose diverse, ed e' il cuore del disegno: NULL vuol dire «mai guardato»,
      # `[]` vuol dire «guardato, e di controlli non ce n'e' nessuno configurato». Se finissero nella
      # stessa casella, «non sono riuscito a guardare» passerebbe come «ho guardato e non c'e'
      # niente» — la seconda passa con la riga rossa, la prima no: si aspetta e si riprova.
      t.jsonb :checks_payload, null: true

      t.datetime :verified_at, null: true
      t.datetime :last_checked_at, null: true
      t.datetime :next_check_at, null: true
      t.integer :checks_count, null: false, default: 0
      t.string :last_error_code, null: true

      t.timestamps
    end

    # La stessa proposta non deve finire due volte nel registro con due esiti diversi: la scheda ne
    # mostrerebbe uno a caso fra i due. `nulls_not_distinct` e' obbligatorio perche' `head_sha` nasce
    # NULL: col comportamento normale di Postgres due righe con SHA nullo sarebbero entrambe ammesse,
    # ed e' proprio il momento in cui il doppione nasce.
    #
    # Il codice fa parte della chiave DI PROPOSITO: se dopo il controllo qualcuno cambia il codice,
    # nasce una riga nuova sul codice nuovo, accanto a quella vecchia che resta li' come prova.
    add_index :agents_delivery_candidates,
              %i[workflow_id repository_full_name number head_sha],
              unique: true, nulls_not_distinct: true,
              name: "index_agents_delivery_candidates_identity"

    # Chi va a ricontrollare legge solo le righe ritentabili e scadute: l'indice parziale tiene fuori
    # tutte le altre, che sono la maggioranza e non torneranno mai.
    add_index :agents_delivery_candidates, :next_check_at,
              where: RITENTABILI_SQL,
              name: "index_agents_delivery_candidates_due"

    # Una riga verificata SENZA il codice, il ramo, l'ora o l'esito dei controlli non e' una prova di
    # niente: dice «ho guardato» senza dire cosa. Il vincolo sta nel database perche' questa riga e'
    # cio' su cui, fra un mese, si rispondera' alla domanda «su quale codice avevo detto di si'».
    add_check_constraint :agents_delivery_candidates,
                         "NOT (#{VERIFICATI_SQL}) OR " \
                         "(head_sha IS NOT NULL AND base_ref IS NOT NULL AND " \
                         "verified_at IS NOT NULL AND checks_payload IS NOT NULL)",
                         name: "agents_delivery_candidates_verified_complete"

    # `agents_workflows.review_candidate_id` ESISTE GIA': l'ha creata CYRA-601, di proposito come
    # uuid nudo senza chiave esterna, perche' la tabella a cui punta nasce qui e una FK l'avrebbe
    # resa non applicabile da sola. Adesso la tabella c'e', quindi la chiave si puo' chiudere: e'
    # l'unica cosa che impedisce alla lavorazione di puntare a una riga che non esiste.
    add_index :agents_workflows, :review_candidate_id
    add_foreign_key :agents_workflows, :agents_delivery_candidates, column: :review_candidate_id
  end
end
