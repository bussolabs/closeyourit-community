# frozen_string_literal: true

# Lista di todo per API CLI. items_count/done_count assumono items caricati (index → includes(:items)).
# owner serve alle liste RICEVUTE (shared_todo_lists) per sapere di chi sono; sulle proprie è sé stessi.
class TodoListSerializer < ApplicationSerializer
  attributes :id, :name, :color, :position, :created_at

  attribute(:items_count) { |list| list.items_count }
  attribute(:done_count)  { |list| list.done_count }

  attribute :owner do |list|
    { id: list.account_id, name: list.account.name, handle: list.account.handle }
  end
end
