# frozen_string_literal: true

module Alerting
  # Alerts about CloseYourIt's own services (AI, embeddings, shared cache) concern the platform, not the
  # customers: they reach only the gods, once each, in the organization of their first membership (CYRA-875).
  module PlatformAlert
    # Throttle at 1h where the check runs often (every 15' for the AI, every minute for the cache).
    RULES = [
      { event_type: "embedding_down", name: "Ricerca per significato non raggiungibile", throttle_seconds: 300 },
      { event_type: "ai_unavailable", name: "Intelligenza artificiale non raggiungibile", throttle_seconds: 3600 },
      { event_type: "ai_available", name: "Intelligenza artificiale ripristinata", throttle_seconds: 300 },
      { event_type: "cache_unavailable", name: "Memoria temporanea non raggiungibile", throttle_seconds: 3600 }
    ].freeze

    def self.event_type?(event_type) = Notifications::Catalog.group_for(event_type) == :services

    def self.notify(event_type:, value:)
      home_organization_ids.values.uniq.each do |organization_id|
        install_rules(organization_id)
        Alerting::EvaluateJob.perform_later(
          event_type: event_type, subject_type: "Organizations::Organization", subject_id: organization_id,
          project_id: nil, organization_id: organization_id, value: value
        )
      end
    end

    def self.recipients(organization)
      god_ids = home_organization_ids.select { |_account_id, organization_id| organization_id == organization.id }.keys
      Accounts::Account.human.where(id: god_ids)
    end

    # god account id → organization of the god's first membership.
    def self.home_organization_ids
      Connections::Membership.joins(:account).where(accounts: { god: true }).order(:created_at)
                             .pluck(:account_id, :organization_id).uniq(&:first).to_h
    end

    # A fresh install has no rule yet, and Alerting::Evaluate drops an event without one.
    def self.install_rules(organization_id)
      RULES.each do |rule|
        Alerting::Rule.find_or_create_by!(organization_id: organization_id, event_type: rule[:event_type]) do |new_rule|
          new_rule.assign_attributes(name: rule[:name], throttle_seconds: rule[:throttle_seconds], enabled: true)
        end
      end
    end
    private_class_method :install_rules
  end
end
