# frozen_string_literal: true

module Github
  module Issues
    # One page of the first import (Github::Issues::FirstImport); the next page is a new job, so a large
    # repository goes in small steps and one page that fails does not undo the others. CYRA-1055
    class FirstImportJob < ApplicationJob
      queue_as :batch

      limits_concurrency to: 1, key: ->(repository_id:, **) { "github:first_import:#{repository_id}" }

      def perform(repository_id:, page: 1)
        repository = Github::Repository.find_by(id: repository_id)
        return if repository.nil?

        next_page = Github::Issues::FirstImport.call(repository:, page:).value
        self.class.perform_later(repository_id:, page: next_page) if next_page
      end
    end
  end
end
