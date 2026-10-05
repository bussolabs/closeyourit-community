# frozen_string_literal: true

module Member
  module PersonalSecretAssetsHelper
    EVENT_ICONS = {
      "uploaded" => "upload",
      "downloaded" => "download",
      "rolled_back" => "history",
      "archived" => "archive",
      "purged" => "trash"
    }.freeze

    def personal_secret_asset_event_icon(action)
      EVENT_ICONS.fetch(action.to_s, "info")
    end
  end
end
