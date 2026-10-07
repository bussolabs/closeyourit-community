# frozen_string_literal: true

# A Puck run for the apps (CYRA-1022): the client polls it while `active` is true and reads the
# partial `output` as it grows, then the actions waiting for a decision.
class CoworkerRunSerializer < ApplicationSerializer
  attributes :id, :puck_id, :kind, :status, :input, :output, :error_code, :channel, :created_at, :ended_at

  attribute(:active) { |run| run.active? }
  attribute(:proposals) do |run|
    run.action_proposals.map do |proposal|
      { id: proposal.id, kind: proposal.kind, status: proposal.status, origin: proposal.origin,
        title: proposal.payload["title"] || proposal.payload["ticket_title"], ticket_code: proposal.payload["ticket_code"] }
    end
  end
end
