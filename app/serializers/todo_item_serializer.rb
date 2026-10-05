# frozen_string_literal: true

# Voce di una lista di todo per API CLI. ticket_code (progetto-KEY-numero) è nil se la voce non
# linka un ticket; assume ticket precaricato (index → includes(ticket: :project)).
class TodoItemSerializer < ApplicationSerializer
  attributes :id, :title, :done, :position, :list_id, :ticket_id, :completed_at, :created_at

  attribute(:ticket_code) { |item| item.ticket&.code }
end
