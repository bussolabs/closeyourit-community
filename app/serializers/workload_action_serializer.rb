# frozen_string_literal: true

# Workload action per la CLI. status = chiave enum ("planned"…). team/ticket_code/created_by/participants
# come riferimenti umani (nomi/code), coerenti con la show web. team_id resta per referenziare l'update.
class WorkloadActionSerializer < ApplicationSerializer
  attributes :id, :title, :description, :status, :team_id, :ticket_id,
             :scheduled_at, :due_at, :completed_at, :created_at, :updated_at

  attribute(:team) { |action| action.team.name }
  attribute(:ticket_code) { |action| action.ticket&.code }
  attribute(:created_by) { |action| action.created_by&.name }
  attribute(:participants) { |action| action.participants.map(&:name) }
end
