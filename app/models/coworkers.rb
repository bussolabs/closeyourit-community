module Coworkers
  def self.enabled?
    default = Rails.env.development? && runtime_root.join("bridge.mjs").file? ? "true" : "false"
    return false unless ENV.fetch("COWORKERS_ENABLED", default) == "true"
    return true if Rails.env.development? || Rails.env.test?

    remote? && worker_configuration_valid?
  end

  def self.runtime_root
    configured = ENV["COWORKERS_RUNTIME_ROOT"]
    return Pathname.new(configured) if configured.present?
    return Rails.root.join("../closeyourit-automator/prototypes/coworkers").cleanpath if Rails.env.development?

    raise KeyError, "COWORKERS_RUNTIME_ROOT is required outside development"
  end

  def self.remote? = ENV.fetch("COWORKERS_RUNTIME", "local") == "remote"

  # The runtime's own reason stays in the log: the run stores only the generic code the page translates.
  def self.log_failure(run, event)
    reason = event["reason"] || (event["code"] == 0 ? "empty_or_unresearched_answer" : event["code"])
    detail = event["detail"].to_s[/\A[a-z_]{3,60}\z/]
    Rails.logger.warn("[coworkers] run #{run.id} failed: #{[ reason, detail ].compact.join(' / ')}")
  end
  def self.worker_token_digest = ENV.fetch("COWORKERS_WORKER_TOKEN_SHA256", "")
  def self.worker_organization_id = ENV.fetch("COWORKERS_ORGANIZATION_ID", "")
  def self.worker_account_ids = ENV.fetch("COWORKERS_ACCOUNT_IDS", "").split(",").map(&:strip).reject(&:empty?)

  def self.worker_configuration_valid?
    worker_token_digest.match?(/\A[a-f0-9]{64}\z/) && worker_organization_id.present? && worker_account_ids.any?
  end

  def self.available_to?(account:, organization:)
    return false unless enabled?
    return true unless remote?

    organization&.id == worker_organization_id && worker_account_ids.include?(account&.id)
  end

  # Who unattended work runs as may still act for the Puck: a member on an allowed host and, for a team
  # Puck, still a manager who sees its project (CYRA-1023).
  def self.can_act?(account, puck)
    return false unless account && available_to?(account: account, organization: puck.organization)
    return false unless Connections::Membership.exists?(account_id: account.id, organization_id: puck.organization_id)
    return true unless puck.team?

    puck.managed_by?(account) && Coworkers::Scope.capture(account: account, organization: puck.organization, puck: puck)["project_ids"].include?(puck.project_id)
  end
end
