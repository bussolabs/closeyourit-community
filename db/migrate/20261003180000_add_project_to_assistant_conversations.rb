# frozen_string_literal: true

# A conversation opened from a project stays fixed on it. Nullify: without its project the
# conversation survives as a plain one.
class AddProjectToAssistantConversations < ActiveRecord::Migration[8.1]
  def change
    add_reference :assistant_conversations, :project, type: :uuid, null: true, index: true,
                                                      foreign_key: { on_delete: :nullify }
  end
end
