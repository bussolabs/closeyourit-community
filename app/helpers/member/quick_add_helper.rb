# frozen_string_literal: true

module Member
  # The "who is it for / what does not go here" line of the quick-add entry point (CYRA-357), reused
  # under the team activities title; the other sections now carry a one-line subtitle (CYRA-883).
  module QuickAddHelper
    def quick_add_purpose(key)
      "#{t("member.quick_add.#{key}.when")} #{t("member.quick_add.#{key}.not_here")}"
    end
  end
end
