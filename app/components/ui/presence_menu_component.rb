# frozen_string_literal: true

module Ui
  # Header control combining the Action Cable state and who is online. Up to four avatars;
  # beyond four it shows three and the fourth carries the count of the others. The trigger is
  # as wide as its content and says "only you" when the viewer is alone (CYRA-898).
  class PresenceMenuComponent < BaseComponent
    PREVIEW_SLOTS = 4
    VISIBLE_BEFORE_OVERFLOW = 3

    def initialize(accounts:, viewer: nil)
      @accounts = Array(accounts)
      @viewer = viewer
    end

    private

    def preview_accounts
      @accounts.first(overflow? ? VISIBLE_BEFORE_OVERFLOW : PREVIEW_SLOTS)
    end

    def overflow?
      @accounts.size > PREVIEW_SLOTS
    end

    def overflow_count
      @accounts.size - VISIBLE_BEFORE_OVERFLOW
    end

    def only_viewer?
      @viewer.present? && @accounts.size == 1 && @accounts.first.id == @viewer.id
    end
  end
end
