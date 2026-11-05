# frozen_string_literal: true

# Identità pubblica di un'installazione Automator. Le colonne della credenziale non appartengono mai
# al serializer; il solo secret appena emesso viene aggiunto esplicitamente dal create controller.
class AgentHostSerializer < ApplicationSerializer
  attributes :id, :fingerprint, :hostname, :platform, :arch, :automator_version,
             :runtimes, :repositories, :last_stops, :running, :slots, :host_status,
             :last_heartbeat_at, :heartbeat_expected_interval_minutes, :heartbeat_grace_minutes,
             :revoked_at, :created_at

  attribute :active_runs do |host|
    host.observable_active_runs
  end

  attribute :online do |host|
    host.heartbeat_online?
  end

  attribute :activity_status do |host|
    host.activity_status
  end
end
