# frozen_string_literal: true

class CreateAgentsTicketQueueDeferrals < ActiveRecord::Migration[8.1]
  REASONS = %w[temporary_failure preflight_blocked needs_clarification].freeze

  def change
    create_table :agents_ticket_queue_deferrals, id: :uuid do |t|
      t.timestamps

      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent, type: :uuid, null: false,
                           foreign_key: { to_table: :agents_agents, on_delete: :cascade }
      t.references :ticket, type: :uuid, null: false, index: false,
                            foreign_key: { to_table: :ticketing_tickets, on_delete: :cascade }
      t.references :host, type: :uuid, null: true,
                          foreign_key: { to_table: :agents_hosts, on_delete: :nullify }
      t.string :reason, null: false
      t.datetime :retry_at, null: false
      t.string :selection_digest, null: false, limit: 64
      t.string :candidate_version, null: false, limit: 64
      t.string :repository_fingerprint, null: false, limit: 64

      t.index %i[organization_id selection_digest], unique: true,
                                                       name: "index_agent_queue_deferrals_selection"
      t.index %i[agent_id ticket_id retry_at], name: "index_agent_queue_deferrals_eligibility"
      t.check_constraint "reason IN (#{REASONS.map { |reason| connection.quote(reason) }.join(', ')})",
                         name: "agents_ticket_queue_deferrals_reason"
      t.check_constraint "retry_at > created_at", name: "agents_ticket_queue_deferrals_positive_backoff"
      t.check_constraint "length(selection_digest) = 64", name: "agents_ticket_queue_deferrals_digest_length"
      t.check_constraint "length(candidate_version) = 64", name: "agents_ticket_queue_deferrals_version_length"
      t.check_constraint "length(repository_fingerprint) = 64",
                         name: "agents_ticket_queue_deferrals_repository_length"
    end
  end
end
