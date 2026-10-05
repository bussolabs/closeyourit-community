# frozen_string_literal: true

module Member
  # CYRA-911 — the Administration pages share one frame: the section list on the left, the page on the
  # right. The sidebar shows the area as a single entry (Navigation::Group `subnav: true`).
  module AdminShellHelper
    # The overview comes from the shared overviews controller, so the route's group_id identifies it;
    # every other page of the area is found through the controller membership.
    def admin_area?
      return false unless current_organization

      overview_active?("settings") || Navigation::Group.for_controller(controller_path)&.id == "settings"
    end

    # The visible sections of the area, in the same groups as the overview page
    # (SpacesHelper#settings_sections), so the two never disagree.
    def admin_nav
      settings_sections(group_leaf_items(Navigation::Group.find("settings")))
    end
  end
end
