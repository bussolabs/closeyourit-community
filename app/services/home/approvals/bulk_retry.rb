# frozen_string_literal: true

module Home
  module Approvals
    # CYRA-1060 — restarts the ticked blocked rows in one go. Same gate as BulkApprove (each key is
    # resolved by Detail, so foreign or stale keys are skipped), same unblock as the row's Retry button.
    # Best-effort like BulkApprove: one failure does not undo the rows already restarted.
    #
    #   Home::Approvals::BulkRetry.call(account:, organization:, visible_projects:, visible_tickets:,
    #     keys: ["agent_plan:…"]) → Result<Outcome>
    class BulkRetry < ApplicationService
      MAX_KEYS = BulkApprove::MAX_KEYS

      Outcome = Data.define(:retried, :skipped, :failures) do
        def failed = failures.size
      end

      def initialize(account:, organization:, visible_projects:, visible_tickets:, keys:)
        @account = account
        @organization = organization
        @visible_projects = visible_projects
        @visible_tickets = visible_tickets
        @keys = Array(keys).map { |key| key.to_s.strip }.reject(&:blank?).uniq
      end

      def call
        return no_keys if @keys.empty?
        return too_many if @keys.size > MAX_KEYS

        cards = Detail.call_many(account: @account, organization: @organization, visible_projects: @visible_projects,
                                 visible_tickets: @visible_tickets, keys: @keys)
        retried = 0
        skipped = 0
        failures = []
        @keys.each do |key|
          card = cards[key]
          next skipped += 1 unless retryable?(card)

          result = safe_unblock(card, key)
          result.ok? ? retried += 1 : failures << BulkApprove::Failure.new(key: key, message: result.error.message)
        end
        Result.ok(Outcome.new(retried: retried, skipped: skipped, failures: failures))
      end

      private

      # Detail offers approve on a blocked plan only when the work is really stopped (#blocked_decisions).
      def retryable?(card)
        card && card.kind == "agent_plan" && card.phase == "review_blocked" && card.can?(:approve)
      end

      def safe_unblock(card, key)
        ::Agents::Workflows::Unblock.call(workflow: card.record, actor: @account)
      rescue StandardError => e
        Rails.logger.warn("BulkRetry: #{key} not restarted — #{e.class}: #{e.message}")
        Result.err(AppError.new(I18n.t("member.approvals.errors.card_failed"), code: "R500-APPROVAL-006"))
      end

      def no_keys
        Result.err(AppError.new(I18n.t("member.approvals.errors.no_selection"), code: "R422-APPROVAL-004"))
      end

      def too_many
        Result.err(AppError.new(I18n.t("member.approvals.errors.too_many", max: MAX_KEYS), code: "R422-APPROVAL-005"))
      end
    end
  end
end
