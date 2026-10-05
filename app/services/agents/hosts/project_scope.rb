# frozen_string_literal: true

module Agents
  module Hosts
    # CYAU-95 — Scope operativo HOST-ONLY: quali progetti un host può lavorare. Autorità UNICA per
    # selection / limits / claim / delivery. L'ORGANIZZAZIONE e il SERVICE ACCOUNT vengono dall'HOST
    # (non più dall'agente tipizzato): scope = progetti VISIBILI al service account dell'host nella sua
    # organizzazione (`Authorization::VisibleScope`). FAIL-CLOSED: un host senza service_account (o senza
    # organizzazione) non vede NULLA → nessun claim possibile (mai fail-open per un host mal configurato).
    # Cross-tenant naturalmente negato: la VisibleScope è vincolata all'org dell'host. `command.allows_project?`
    # resta verificato ESPLICITAMENTE dai chiamanti (policy del comando), non qui.
    class ProjectScope
      def initialize(host:)
        @host = host
      end

      # ActiveRecord::Relation dei progetti che questo host può lavorare. FAIL-CLOSED: un host senza
      # service account o senza organizzazione non vede NULLA (`none`, mai l'intero catalogo dell'org).
      # È la stessa fonte di `allows?`, esposta come insieme per i chiamanti che devono ELENCARE invece
      # che verificare (WorkspaceManifest, CYAU-100).
      def projects
        return Projects::Project.none unless @host&.service_account && @host.organization

        Authorization::VisibleScope.new(account: @host.service_account, organization: @host.organization).projects
      end

      def allows?(project)
        return false if project.nil?

        projects.exists?(project.id)
      end
    end
  end
end
