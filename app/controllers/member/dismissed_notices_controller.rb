# frozen_string_literal: true

module Member
  # Ui::FloatingNoticeComponent — closing a notice saves its key on the account, so it does not come
  # back on any device. The DOM is already updated by the close button: nothing to render.
  class DismissedNoticesController < Member::BaseController
    permission_not_required "Dismissed notices: a personal preference, written on one's own account."

    def create
      key = params[:key].to_s
      return head :unprocessable_content unless Ui::FloatingNoticeComponent.valid_key?(key)

      account = Current.account
      # Only the last release seen matters: the older ones would pile up, one per version.
      kept = key.start_with?("release:") ? account.dismissed_notices.grep_v(/\Arelease:/) : account.dismissed_notices
      account.update!(dismissed_notices: (kept + [ key ]).uniq)
      head :no_content
    end
  end
end
