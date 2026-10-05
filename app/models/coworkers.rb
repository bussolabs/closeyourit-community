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
end
