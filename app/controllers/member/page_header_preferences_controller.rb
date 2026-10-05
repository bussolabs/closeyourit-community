# frozen_string_literal: true

module Member
  # DESIGN.md B25 — the page header's toggle saves whether the person wants it collapsed, on the
  # account, for every member page. The DOM is already updated by the toggle: nothing to render.
  class PageHeaderPreferencesController < Member::BaseController
    permission_not_required "Collapsed page header: a personal preference, written on one's own account."

    def update
      Current.account.update!(page_header_compact: ActiveModel::Type::Boolean.new.cast(params[:compact]) || false)
      head :no_content
    end
  end
end
