# frozen_string_literal: true

module Github
  module Webhooks
    # Evento `release` (action published): arricchisce la release live col link alla GitHub Release e
    # rinforza il binding sul tag_name.
    class Release < Base
      def call
        return Result.ok(nil) unless value_at(@payload, "action") == "published"

        release = object_at(@payload, "release")
        tag = value_at(release, "tag_name").to_s
        return Result.ok(nil) if tag.blank?

        bind_tag(tag, git_tag_url: value_at(release, "html_url"))
      end
    end
  end
end
