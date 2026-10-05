# frozen_string_literal: true

# Commento su un'idea (la discussione del team che l'AI sintetizza alla conversione in ticket).
# Specchio di ticketing_comments: FK senza on_delete — la cascata è applicativa (AR dependent:
# :destroy su idea e account, come authored_comments). counter_cache → ideas_ideas.comments_count.
class CreateIdeasComments < ActiveRecord::Migration[8.1]
  def change
    create_table :ideas_comments, id: :uuid do |t|
      t.timestamps

      t.references :idea, type: :uuid, null: false,
                   foreign_key: { to_table: :ideas_ideas }
      t.references :author, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts }

      t.text :body, null: false
    end
  end
end
