# frozen_string_literal: true

class AgentTicketQueueDeferralSerializer < ApplicationSerializer
  attributes :id, :host_id, :execution_phase, :reason, :retry_at, :created_at

  attribute(:ticket) { |deferral| deferral.ticket.code }
end
