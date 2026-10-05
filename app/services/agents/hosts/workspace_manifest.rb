# frozen_string_literal: true

module Agents
  module Hosts
    # Struttura dei repository che un Agent Host deve clonare per replicare la workspace locale.
    # È il contratto "OneClick" servito all'automator: path logico + coordinate GitHub per progetto,
    # più un digest stabile che consente al client di rilevare cambi senza ridiffare l'intero albero.
    #
    # Host-first (CYAU-100): il manifest è PER-HOST e deriva dalla stessa autorità che governa claim,
    # limits e delivery — `Agents::Hosts::ProjectScope`, cioè i progetti visibili al service account
    # dell'host. Prima veniva dagli agenti tipizzati (`organization.agents.enabled`), ultimo consumatore
    # Rails che ne impediva la rimozione (MT-9). Manifest ed `Eligibility` ora concordano per costruzione:
    # ciò che l'host clona è esattamente ciò che potrà reclamare.
    class WorkspaceManifest < ApplicationService
      WORKSPACE_ROOT_HINT = "Lavoro/Github/Personale"

      def initialize(host:)
        @host = host
      end

      def call
        repositories = authorized_projects.map { |project| repository_entry(project) }.sort_by { |entry| entry[:path] }

        Result.ok(
          version: 1,
          digest: Digest::SHA256.hexdigest(repositories.to_json),
          workspace_root_hint: WORKSPACE_ROOT_HINT,
          repositories: repositories
        )
      end

      private

      # Progetti visibili al service account dell'host che hanno davvero un repo GitHub: senza repo non
      # c'è nulla da clonare, ed è la stessa condizione che `Eligibility` esige per il claim. La relation
      # è già unica per progetto (nessuna dedup manuale); `joins` filtra, `preload` evita l'N+1 su
      # repository e gruppo senza collidere con l'alias del join.
      def authorized_projects
        Agents::Hosts::ProjectScope.new(host: @host)
                                   .projects
                                   .joins(:github_repository)
                                   .preload(:github_repository, :group)
                                   .to_a
      end

      def repository_entry(project)
        repository = project.github_repository
        {
          project_key: project.key,
          path: workspace_path_for(project),
          repo: repository.full_name,
          default_branch: repository.default_branch,
          group: project.group&.name
        }
      end

      # Path logico esplicito (seed dal master) o derivato: sotto la cartella del gruppo se presente,
      # altrimenti la sola cartella del repo.
      def workspace_path_for(project)
        project.workspace_path.presence || derived_path(project)
      end

      def derived_path(project)
        repo_name = project.github_repository.full_name.split("/").last
        return repo_name if project.group.nil?

        "#{project.group.name.parameterize}/#{repo_name}"
      end
    end
  end
end
