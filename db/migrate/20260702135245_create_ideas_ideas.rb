# frozen_string_literal: true

# Idea di progetto: proposta grezza del team, votabile e commentabile, promuovibile a ticket
# (pattern Errors::Group#ticket_id). L'autore è metadato "creato da" → on_delete nullify (l'idea
# sopravvive all'account). ticket_id unico parziale: un ticket nasce da UNA sola idea.
class CreateIdeasIdeas < ActiveRecord::Migration[8.1]
  def change
    create_table :ideas_ideas, id: :uuid do |t|
      t.timestamps

      t.references :project, type: :uuid, null: false,
                   foreign_key: { to_table: :projects, on_delete: :cascade }
      t.references :author, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :ticket, type: :uuid, null: true, index: false,
                   foreign_key: { to_table: :ticketing_tickets, on_delete: :nullify }

      t.string  :title, null: false
      t.text    :body, null: false
      t.integer :status, null: false, default: 0
      t.integer :votes_count, null: false, default: 0
      t.integer :comments_count, null: false, default: 0
      t.datetime :converted_at
    end

    add_index :ideas_ideas, %i[project_id status]
    add_index :ideas_ideas, :votes_count
    add_index :ideas_ideas, :ticket_id, unique: true, where: "ticket_id IS NOT NULL"
  end
end
