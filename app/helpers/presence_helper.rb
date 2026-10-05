# frozen_string_literal: true

# The topbar renders who is already online, so the count does not start from zero on every page
# and then jump when the channel snapshot arrives.
module PresenceHelper
  def presence_online_for(organization, viewer)
    Presence::Cohort.visible_online(organization, viewer)
  end
end
