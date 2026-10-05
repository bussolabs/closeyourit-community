# frozen_string_literal: true

# Contesto attorno a "Chiedi alla KB" (CYRA-421): la schermata era un campo vuoto senza esempi,
# senza scope e senza memoria. Due tabelle, due nature diverse:
#
# - knowledge_sample_questions: SEMI delle domande d'esempio, precalcolati da un giro notturno
#   (Knowledge::GenerateSampleQuestionsJob) dalle pagine reali di OGNI progetto. Memorizza il titolo
#   e il tipo della pagina — NON il testo già reso — così la domanda si compone a display nella lingua
#   dell'utente (it/en) invece di restare congelata nella lingua del job. Ancorate al progetto: chi
#   vede il progetto vede i suoi esempi.
# - knowledge_ask_logs: STORICO condiviso delle domande poste dal team, con la risposta e le pagine
#   citate, così una domanda già pagata non viene rifatta da zero. Porta lo snapshot dello scope
#   (full_access + project_ids/group_ids) su cui è stata eseguita: la visibilità dello storico ricalca
#   ESATTAMENTE quella delle pagine (Knowledge::Page.visible_to), altrimenti esporrebbe domande di
#   progetti che un membro non vede.
class CreateKnowledgeAskContext < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_sample_questions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      # La pagina sorgente: nullify, non cascade — se la pagina sparisce il seme resta valido fino al
      # prossimo giro notturno (il titolo è già snapshot qui), non serve cancellarlo subito.
      t.references :knowledge_page, type: :uuid, null: true,
                                    foreign_key: { to_table: :knowledge_pages, on_delete: :nullify }
      t.string :title, null: false, comment: "Snapshot del titolo pagina: la domanda si compone a display via i18n"
      t.integer :kind, null: false, comment: "Tipo pagina (note/decision/guide): sceglie il template della domanda"
      t.integer :position, default: 0, null: false
      t.timestamps

      t.index %i[organization_id project_id]
    end

    create_table :knowledge_ask_logs, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      # Chi ha posto la domanda. Cascade: se l'account sparisce, la sua domanda esce dallo storico.
      t.references :account, type: :uuid, null: false, foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.text :question, null: false
      t.text :answer, comment: "Risposta generata; nil quando la KB non aveva abbastanza informazioni"
      t.boolean :insufficient, default: false, null: false
      # Snapshot dello scope autorizzato all'enqueue: la visibilità dello storico lo confronta con lo
      # scope del lettore, come Knowledge::Page.visible_to fa per le pagine.
      t.boolean :full_access, default: false, null: false
      t.uuid :project_ids, array: true, default: [], null: false
      t.uuid :group_ids, array: true, default: [], null: false
      t.jsonb :citations, default: [], null: false, comment: "Pagine citate {id,title,kind,kind_label,url} per riaprire la risposta"
      t.timestamps

      t.index %i[organization_id created_at]
      t.index :project_ids, using: :gin
      t.index :group_ids, using: :gin
    end
  end
end
