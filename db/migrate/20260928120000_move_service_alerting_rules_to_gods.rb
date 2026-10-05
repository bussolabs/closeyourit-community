# frozen_string_literal: true

# CYRA-875 — alerts about CloseYourIt's own services go only to the gods. Their rules leave the
# customer organizations; each god's organization (first membership) keeps them, and
# Alerting::PlatformAlert installs them there when missing. Past notifications stay (rule_id → null).
class MoveServiceAlertingRulesToGods < ActiveRecord::Migration[8.1]
  # Raw append-only integers of Alerting::Rule#event_type: embedding_down, ai_unavailable, ai_available,
  # cache_unavailable.
  EVENT_TYPES = [ 34, 49, 50, 52 ].freeze

  class Membership < ActiveRecord::Base
    self.table_name = "connections_memberships"
  end

  class Account < ActiveRecord::Base
    self.table_name = "accounts"
  end

  class Rule < ActiveRecord::Base
    self.table_name = "alerting_rules"
  end

  class HostExclusion < ActiveRecord::Base
    self.table_name = "alerting_rule_host_exclusions"
  end

  def up
    god_organization_ids = Membership.where(account_id: Account.where(god: true).select(:id)).order(:created_at)
                                     .pluck(:account_id, :organization_id).uniq(&:first).map(&:last).uniq

    customer_rules = Rule.where(event_type: EVENT_TYPES).where.not(organization_id: god_organization_ids)
    HostExclusion.where(rule_id: customer_rules.select(:id)).delete_all
    customer_rules.delete_all
  end

  def down
    # The deleted rules may have been edited by their owners: they cannot be rebuilt faithfully.
  end
end
