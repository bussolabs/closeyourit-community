# frozen_string_literal: true

module Projects
  module Moves
    # No stored list says which repositories an installation sees (only a live API call
    # does), and the destination cannot hold a second row for the same repo: the link is detached (CYRA-879).
    module Github
      module_function

      def preview(subject)
        repositories = repositories(subject)
        dependents = dependent_counts(repositories.map(&:id)).filter_map do |table, count|
          { table:, count: } if count.positive?
        end
        repositories.map { { table: "github_repositories", count: 1 } } + dependents
      end

      # Agent rows keep no cascade on the repository: the nullable link is cleared, the required one
      # goes with its row; destroy! then removes branches and pull requests (CYRA-879).
      def apply!(subject)
        repositories = repositories(subject)
        ids = repositories.map(&:id)
        Agents::DeliveryCandidate.where(repository_id: ids).update_all(repository_id: nil)
        Agents::ReleaseAssignment.where(github_repository_id: ids).delete_all
        drop_github_signature(subject)
        repositories.each(&:destroy!)
      end

      # The source's GitHub account stops seeing the moved projects: it is not a member over there (CYRA-1055).
      def drop_github_signature(subject)
        signatures = ::Github::Installation.where(organization_id: subject.organization.id).select(:system_account_id)
        Connections::ProjectMembership.where(project_id: subject.project_ids, account_id: signatures).delete_all
      end

      # The issue links go with their repository; the tickets stay, unlinked (CYRA-1055).
      def dependent_counts(ids)
        { "agents_delivery_candidates" => Agents::DeliveryCandidate.where(repository_id: ids).count,
          "agents_release_assignments" => Agents::ReleaseAssignment.where(github_repository_id: ids).count,
          "github_issues" => ::Github::Issue.where(repository_id: ids).count }
      end

      def repositories(subject) = ::Github::Repository.where(project_id: subject.project_ids).to_a
    end
  end
end
