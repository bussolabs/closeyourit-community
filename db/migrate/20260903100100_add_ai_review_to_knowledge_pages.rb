# frozen_string_literal: true

# Il verdetto del revisore automatico (CYRA-764) sul testo live di una pagina. Nessun backfill qui:
# lo fa Knowledge::ReclassifyPagesJob, una pagina alla volta, perché ogni verdetto è una chiamata al
# server AI di casa. NULL = mai giudicata.
class AddAiReviewToKnowledgePages < ActiveRecord::Migration[8.1]
  def change
    change_table :knowledge_pages, bulk: true do |t|
      t.string :ai_review_format
      t.integer :ai_review_verdict
      t.jsonb :ai_review_violations, null: false, default: []
      t.datetime :ai_reviewed_at
      t.string :ai_review_model
    end
    add_index :knowledge_pages, [ :organization_id, :ai_review_verdict ]
  end
end
