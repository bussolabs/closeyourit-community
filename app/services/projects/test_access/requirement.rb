# frozen_string_literal: true

module Projects
  module TestAccess
    # CYRA-1304 — a project that has a staging environment is worked by the agents only once its test
    # account is filled in: link, user and password. Without it nobody, person or agent, can try the work
    # on staging, so the queue hands out nothing. A project with no staging has nowhere to sign in and is
    # left alone. So is one that declares it has no sign-in to try (test_access_not_needed).
    module Requirement
      def self.required?(project) = SavePassword.environment(project).present? && !project.test_access_not_needed?

      def self.complete?(project)
        project.test_access_url.present? && project.test_access_username.present? && SavePassword.set?(project)
      end

      def self.missing?(project) = required?(project) && !complete?(project)
    end
  end
end
