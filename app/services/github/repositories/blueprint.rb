# frozen_string_literal: true

module Github
  module Repositories
    # Reads blueprint.json from the project's repository for the Map tab. Read only: the map changes
    # in the repository, together with the code (CYRA-1071).
    class Blueprint < ApplicationService
      PATH = "blueprint.json"

      Reading = Data.define(:state, :document, :source_url, :problem)

      def initialize(project:, client: nil)
        @project = project
        @client = client
      end

      def call
        repository = @project.github_repository
        return reading(:no_repository) if repository.nil?

        source_url = "#{repository.html_url}/blob/#{repository.default_branch}/#{PATH}"
        raw = client.repository_file(repository.github_installation_id, repository.full_name, PATH,
                                     ref: repository.default_branch)
        return reading(:missing, source_url:) if raw.nil?

        reading(:ready, source_url:, document: ::Blueprint::Document.parse(raw))
      rescue ::Blueprint::Document::Invalid => e
        reading(:invalid, source_url:, problem: e.message)
      rescue Github::Client::Error
        reading(:unreachable, source_url:)
      end

      private

      def client = @client ||= Github::Client.new

      def reading(state, source_url: nil, document: nil, problem: nil)
        Reading.new(state:, document:, source_url:, problem:)
      end
    end
  end
end
