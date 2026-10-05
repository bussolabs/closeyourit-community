# frozen_string_literal: true

module Ai
  # The monthly token cap of an organization (CYRA-914): checked before each chat call, counted after.
  # The cap comes from Ai::Configuration#monthly_token_cap; nil means no cap, as before. Calls made
  # outside an organization (health checks, platform jobs) are neither checked nor counted.
  module TokenBudget
    EXHAUSTED_CODE = "R402-AI-002"

    module_function

    def check!(organization_id)
      return if organization_id.nil?

      cap = Ai::Configuration.for_id(organization_id).monthly_token_cap
      return if cap.nil? || spent(organization_id) < cap

      raise Ai::Llm::Client::Error.new(I18n.t("ai.token_cap_reached"), code: EXHAUSTED_CODE, status: :payment_required)
    end

    def record(organization_id, tokens)
      return if organization_id.nil? || tokens.to_i <= 0

      now = Time.current
      Ai::UsageMonth.upsert({ organization_id:, month: now.to_date.beginning_of_month, tokens: tokens.to_i,
                              created_at: now, updated_at: now },
                            unique_by: %i[organization_id month],
                            on_duplicate: Arel.sql("tokens = ai_usage_months.tokens + EXCLUDED.tokens, updated_at = EXCLUDED.updated_at"))
    rescue ActiveRecord::ActiveRecordError => e
      # The provider already answered: losing one count is better than losing the answer.
      Rails.logger.error("[Ai::TokenBudget] usage not recorded for #{organization_id}: #{e.class}")
    end

    def spent(organization_id)
      Ai::UsageMonth.where(organization_id:, month: Time.current.to_date.beginning_of_month).pick(:tokens).to_i
    end
  end
end
