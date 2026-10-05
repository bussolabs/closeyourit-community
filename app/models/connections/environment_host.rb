# frozen_string_literal: true

module Connections
  # Join server ↔ environment di progetto: N host per coppia [project, environment].
  # Attivabile solo su progetti uptime-capable (stesso gate di Uptime::Monitor); l'environment
  # dev'essere DICHIARATO dal progetto (subset) — il tenant dell'environment è quindi già
  # garantito transitivamente da Connections::ProjectEnvironment, resta da validare l'host.
  # Un link il cui environment viene s-dichiarato resta in DB ma invisibile (scope declared),
  # come i monitor orfani.
  class EnvironmentHost < ApplicationRecord
    belongs_to :project,
               class_name: "Projects::Project",
               inverse_of: :server_links
    belongs_to :environment,
               class_name: "Types::Environment",
               inverse_of: :host_links
    belongs_to :host,
               class_name: "Servers::Host",
               inverse_of: :environment_links
    belongs_to :created_by, class_name: "Accounts::Account", optional: true

    validates :host_id, uniqueness: { scope: %i[project_id environment_id], message: :host_already_linked }
    validate :environment_declared_by_project
    validate :project_supports_uptime
    validate :host_matches_project_organization
    # Solo alla creazione: revocare un host DOPO non invalida i link esistenti.
    validate :host_not_revoked, on: :create
    # Capability per-ambiente: i server devono essere abilitati (risolto default+override) su [progetto,
    # ambiente]. Solo alla creazione: disabilitare la capability DOPO non invalida i link esistenti.
    validate :servers_capability_enabled, on: :create

    # Link il cui environment è ANCORA dichiarato dal progetto (gli stale restano in DB
    # ma invisibili; ri-dichiarare l'environment li fa riapparire).
    scope :declared, lambda {
      joins("INNER JOIN connections_project_environments cpe " \
            "ON cpe.project_id = connections_environment_hosts.project_id " \
            "AND cpe.environment_id = connections_environment_hosts.environment_id")
    }

    private

    def environment_declared_by_project
      return if project.blank? || environment.blank?

      errors.add(:environment, :invalid) unless project.environment_ids.include?(environment_id)
    end

    def project_supports_uptime
      return if project.blank?

      errors.add(:project, :uptime_unsupported) unless project.supports_uptime?
    end

    def host_matches_project_organization
      return if project.blank? || host.blank?

      errors.add(:host, :cross_tenant) if host.organization_id != project.organization_id
    end

    def host_not_revoked
      return if host.blank?

      errors.add(:host, :revoked_host) if host.revoked?
    end

    # Flag RISOLTO (default ambiente + eventuale override progetto) dalla riga join, garantita al create
    # da environment_declared_by_project (no-op se assente).
    def servers_capability_enabled
      return if project.blank? || environment.blank?

      link = project.project_environments.find_by(environment_id: environment_id)
      errors.add(:base, :servers_disabled) if link && !link.servers_enabled?
    end
  end
end
