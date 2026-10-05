# frozen_string_literal: true

module Member
  # What the member footer signals next to its buttons.
  module FooterHelper
    # The person's own support requests nobody has handled yet, in this organization.
    def footer_open_support_requests
      Support::Request.pending.where(account: Current.account, organization: current_organization).count
    end

    # The current release has not been opened from the footer yet (saved on the account once it is).
    def footer_release_unseen?
      release = Changelog.current
      release.present? && !Current.account&.notice_dismissed?(Ui::ChangelogComponent.seen_key(release))
    end
  end
end
