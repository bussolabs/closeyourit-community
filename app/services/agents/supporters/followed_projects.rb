# frozen_string_literal: true

module Agents
  module Supporters
    # CYRA-1197 — the supporter is offered only work on projects the machine has a checkout of: it cannot run a
    # session elsewhere, and an item it must skip came back every round while the rest waited. A machine that
    # reports no project list is not filtered.
    module FollowedProjects
      module_function

      def condition(host) = host.repositories.presence ? { projects: { key: host.repositories } } : {}
    end
  end
end
