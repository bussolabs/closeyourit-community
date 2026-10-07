module Coworkers
  # A monthly token ceiling for an organization's Puckies (CYRA-1027). Active runs count with their
  # reservation, finished ones with what they really used; the month is the UTC calendar month.
  class Budget < ApplicationRecord
    self.table_name = "coworkers_budgets"
    belongs_to :organization, class_name: "Organizations::Organization"
    validates :monthly_token_cap, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

    def self.cap_for(organization) = find_by(organization_id: organization.id)&.monthly_token_cap

    def self.used_this_month(organization, at: Time.current)
      Run.joins(:puck).where(coworkers_puckies: { organization_id: organization.id })
         .where(created_at: at.utc.beginning_of_month..)
         .sum(Arel.sql("CASE WHEN coworkers_runs.status IN ('queued', 'running') " \
                       "THEN GREATEST(coworkers_runs.tokens_reserved, coworkers_runs.tokens_used) " \
                       "ELSE coworkers_runs.tokens_used END"))
    end

    def self.allows?(organization, tokens)
      cap = cap_for(organization)
      cap.nil? || used_this_month(organization) + tokens <= cap
    end
  end
end
