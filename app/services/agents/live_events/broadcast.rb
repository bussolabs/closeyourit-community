# frozen_string_literal: true

module Agents
  module LiveEvents
    # CYRA-1138 — tells the open live pages that new steps arrived. Only the signal travels: each page reloads
    # its frame with the viewer's own session, so project visibility is checked again. One signal per project:
    # a step of one agent can open or close a conflict on the page of another agent of the same project.
    module Broadcast
      FRAME = "automator-live"

      module_function

      def moved(attempt, project_id:)
        Realtime::ThrottledRefresh.call(Realtime::Streams.automator_live_project(organization_id: attempt.organization_id, project_id:),
                                        frame: FRAME)
      end
    end
  end
end
