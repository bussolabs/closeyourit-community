# frozen_string_literal: true

module Github
  module Issues
    # The "GitHub" account of an organization: created once, without web access (a service account), it
    # signs the tickets and comments born on GitHub. It sees only the projects whose issues it carries.
    # CYRA-1055
    class SystemAccount < ApplicationService
      NAME = "GitHub"

      def initialize(installation:, project:)
        @installation = installation
        @project = project
      end

      def call
        result = nil
        @installation.with_lock(requires_new: true) do
          account = @installation.system_account || create_account
          if account.is_a?(Result)
            result = account
            raise ActiveRecord::Rollback
          end

          Connections::ProjectMembership.find_or_create_by!(account:, project: @project)
          result = Result.ok(account)
        end
        result
      end

      private

      def create_account
        organization = @installation.organization
        result = Accounts::Service::Create.call(organization:, name: NAME, handle: "github_#{organization.slug}")
        return result if result.err?

        @installation.update!(system_account: result.value)
        result.value
      end
    end
  end
end
