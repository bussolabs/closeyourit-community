# frozen_string_literal: true

# Voto (upvote) di un account su un'idea: un account vota un'idea una volta sola.
# Clone di CreateConnectionsTicketVotes: tenant-integrity validata sul model, on_delete cascade
# su entrambe le FK (un voto è opinione, non evidenza → muore con l'idea e con l'account).
class CreateConnectionsIdeaVotes < ActiveRecord::Migration[8.1]
  def change
    create_table :connections_idea_votes, id: :uuid do |t|
      t.timestamps

      t.references :account, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.references :idea, type: :uuid, null: false,
                   foreign_key: { to_table: :ideas_ideas, on_delete: :cascade }
    end

    add_index :connections_idea_votes, %i[account_id idea_id], unique: true
  end
end
