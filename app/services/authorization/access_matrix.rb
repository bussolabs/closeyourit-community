# frozen_string_literal: true

require "set"

module Authorization
  # Snapshot dei permessi EFFETTIVI di un account su un insieme di progetti, calcolato con UN solo
  # Resolver (cache per-istanza → niente N+1). Read-only: nessuna scrittura. Per ogni progetto l'insieme
  # delle chiavi SCOPED concesse; a parte l'insieme delle chiavi ORG-LEVEL concesse (indipendenti dallo
  # scope). Fonte di verità = Authorization::Resolver + Authorization::Catalog. Base dello schema what-if.
  class AccessMatrix < ApplicationService
    # Chiavi in ordine di dichiarazione del Catalog (ordine stabile per la UII).
    SCOPED_KEYS = Authorization::Catalog.all.select { |e| e[:scoped] }.map { |e| e[:key] }.freeze
    ORG_KEYS    = Authorization::Catalog.all.reject { |e| e[:scoped] }.map { |e| e[:key] }.freeze

    Snapshot = Data.define(:project_keys, :org_keys) do
      # Chiavi scoped concesse su un progetto (Set), vuoto se il progetto non è nella matrice.
      def keys_for(project_id) = project_keys.fetch(project_id, Set.new)
    end

    def initialize(account:, organization:, projects:)
      @account = account
      @organization = organization
      @projects = projects
    end

    def call
      resolver = Authorization::Resolver.new(account: @account, organization: @organization)
      project_keys = @projects.each_with_object({}) do |project, acc|
        acc[project.id] = SCOPED_KEYS.select { |key| resolver.can?(key, scope: project) }.to_set
      end
      org_keys = ORG_KEYS.select { |key| resolver.can?(key) }.to_set
      Snapshot.new(project_keys: project_keys, org_keys: org_keys)
    end
  end
end
