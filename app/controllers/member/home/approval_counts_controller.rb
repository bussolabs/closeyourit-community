# frozen_string_literal: true

module Member
  module Home
    # The number next to Approvals in the sidebar (CYRA-903): decisions waiting for this account, the
    # same Queue as the approvals page minus the rows where the ball is with someone else.
    class ApprovalCountsController < Member::BaseController
      permission_not_required "Counts the viewer's own approval queue: the Queue resolves from the visible scopes."

      # The last count, shown inside the lazy frame of the next page so the badge does not blink.
      def self.cache_key(account, organization) = [ "nav-approvals-count", organization.id, account.id ]

      def show
        queue = ::Home::Approvals::Queue.call(account: Current.account, organization: current_organization,
                                              visible_projects: visible.projects, visible_tickets: visible.tickets)
        @count = queue.total - queue.totals[::Home::Approvals::Queue::WAITING_STATE].to_i
        Rails.cache.write(self.class.cache_key(Current.account, current_organization), @count, expires_in: 1.hour)
        render layout: false
      end
    end
  end
end
