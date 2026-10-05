# frozen_string_literal: true

# Resoconto di lavorazione di un ticket (CYRA-220). Finora viveva dentro un commento: 562 commenti su
# 587 superavano i 240 caratteri e la discussione non si leggeva più. Qui il resoconto ha una tabella
# sua, con la storia delle versioni.
#
# UNA tabella sola, non HEAD + versioni come Knowledge::Page/Knowledge::Version: lì la pagina ha campi
# che le versioni non hanno (slug, embedding), qui "corrente" e "versione" hanno la stessa identica
# forma. Il corrente è max(version), non una riga da tenere sincronizzata — nessun HEAD che può
# divergere. Pattern preso da agents_plans (unique [workflow_id, version] + assign_version).
#
# source_comment_id porta la chiave di idempotenza della migrazione dati: un commento già trasformato
# in versione non può produrne una seconda, quindi il rake è ri-eseguibile senza duplicare niente.
class CreateTicketingReports < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_reports, id: :uuid do |t|
      t.references :ticket, null: false, type: :uuid,
                   foreign_key: { to_table: :ticketing_tickets, on_delete: :cascade }
      # L'autore può sparire (account cancellato) senza portarsi via il resoconto: il nome resta
      # congelato in author_name, come fa knowledge_versions.
      t.references :author, null: true, type: :uuid,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.string :author_name
      t.integer :version, null: false
      t.text :body, null: false
      t.integer :source, null: false, default: 0 # manual / agent / migrated
      t.references :source_comment, null: true, type: :uuid,
                   foreign_key: { to_table: :ticketing_comments, on_delete: :nullify },
                   index: false
      t.timestamps

      t.index %i[ticket_id version], unique: true
    end

    # Parziale: i resoconti scritti a mano o dalla CLI non hanno un commento di origine, e più NULL
    # non violano un unique — ma l'indice parziale lo dice esplicitamente e resta piccolo.
    add_index :ticketing_reports, :source_comment_id, unique: true,
              where: "source_comment_id IS NOT NULL"
  end
end
