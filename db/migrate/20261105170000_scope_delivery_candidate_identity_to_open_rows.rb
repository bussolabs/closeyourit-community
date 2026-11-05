# frozen_string_literal: true

# The same code can be judged more than once: a person who unblocks a red result without new code asks
# for a fresh read of the same head. Uniqueness stays on the open row (no head yet), which keeps a repeated
# delivery from opening a second one; verified rows are an append-only record of each read.
class ScopeDeliveryCandidateIdentityToOpenRows < ActiveRecord::Migration[8.1]
  def up
    remove_index :agents_delivery_candidates, name: "index_agents_delivery_candidates_identity"
    add_index :agents_delivery_candidates, %i[workflow_id repository_full_name number],
              unique: true, where: "head_sha IS NULL", name: "index_agents_delivery_candidates_open_identity"
  end

  def down
    remove_index :agents_delivery_candidates, name: "index_agents_delivery_candidates_open_identity"
    add_index :agents_delivery_candidates, %i[workflow_id repository_full_name number head_sha],
              unique: true, nulls_not_distinct: true, name: "index_agents_delivery_candidates_identity"
  end
end
