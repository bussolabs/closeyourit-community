# frozen_string_literal: true

module HelpdeskHelper
  # Badge color of a help desk request status (keys of Ui::BadgeComponent::COLORS).
  STATUS_COLORS = { "received" => :indigo, "converted" => :emerald, "linked" => :emerald, "answered" => :amber, "discarded" => :gray }.freeze

  def helpdesk_status_color(status) = STATUS_COLORS.fetch(status.to_s, :gray)
end
