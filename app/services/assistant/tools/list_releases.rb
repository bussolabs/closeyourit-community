# frozen_string_literal: true

module Assistant
  module Tools
    # The releases of ONE project, newest first, with the one that is live in each environment.
    class ListReleases < Base
      def self.declaration
        { name: "list_releases",
          description: "Elenca i rilasci di UN progetto dal più recente: versione, ambiente, quando, " \
                       "quale è quello in linea e quanti errori ha raccolto. " \
                       "Usalo per domande come 'qual è l'ultima versione di CYRA?'.",
          parameters: {
            type: "OBJECT",
            properties: { project: { type: "STRING", description: "Chiave del progetto, es. CYRA" } },
            required: [ "project" ]
          } }
      end

      def call(args)
        project = context.find_project(args["project"])
        return not_visible(args["project"]) if project.nil?

        scope = ::Projects::Release.where(project_id: project.id)
        rows = scope.recent.limit(MAX_ROWS).map do |release|
          { version: release.display_version, environment: release.environment, live: release.current,
            released_at: (release.deployed_at || release.created_at).iso8601, errors: release.events_count }
        end

        { project: project.key, total: scope.count, showing: rows.size, releases: rows }
      end
    end
  end
end
