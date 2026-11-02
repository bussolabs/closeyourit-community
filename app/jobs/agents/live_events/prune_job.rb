# frozen_string_literal: true

module Agents
  module LiveEvents
    # CYAU-282 — the steps keep names, counts and line numbers but lose their code once the ticket is concluded or the
    # project switches the code view off; every step goes after the retention.
    class PruneJob < ApplicationJob
      queue_as :batch

      RETENTION = 14.days

      def perform
        ::Agents::AttemptLiveEvent.where(created_at: ...RETENTION.ago).in_batches(&:delete_all)
        with_code.where(attempt_id: code_not_kept).in_batches do |batch|
          batch.update_all(STRIP_TEXT) # rubocop:disable Rails/SkipsModelValidations
        end
      end

      # Only the text goes: the line numbers carry no code and the conflict check reads them (CYAU-299).
      STRIP_TEXT = <<~SQL.squish
        payload = jsonb_set(payload, '{hunks}', (
          SELECT jsonb_agg(hunk || '{"lines": []}'::jsonb) FROM jsonb_array_elements(payload -> 'hunks') AS hunk
        ))
      SQL

      private

      def with_code
        ::Agents::AttemptLiveEvent.where(kind: "file_change").where("jsonb_path_exists(payload, '$.hunks[*].lines[0]')")
      end

      def code_not_kept
        attempts = ::Agents::Attempt.joins(workflow: { ticket: %i[status project] })
        attempts.where(types_ticket_statuses: { category: ::Types::TicketStatus.categories[:done] })
                .or(attempts.where(projects: { automator_live_code_enabled: false }))
                .select(:id)
      end
    end
  end
end
