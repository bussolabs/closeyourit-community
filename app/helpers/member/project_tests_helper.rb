# frozen_string_literal: true

module Member
  # How the Tests tab of a project writes an outcome (CYRA-1165). A failure covered by a valid known
  # failure reads «known», in its own tint, so a new failure is the only red on the page.
  module ProjectTestsHelper
    TEST_STATUS_COLORS = { "passed" => :emerald, "failed" => :red, "skipped" => :gray, "known" => :indigo }.freeze

    def test_status_badge(status, known: false, test_id: nil)
      return tag.span("—", class: "text-gray-400 dark:text-zinc-500") if status.blank?

      shown = known && status == "failed" ? "known" : status
      render Ui::BadgeComponent.new(label: t("member.project_tests.status.#{shown}"),
                                    color: TEST_STATUS_COLORS.fetch(shown, :gray), size: :sm, test_id: test_id)
    end

    # Milliseconds as people read them: 840 ms, 2.4 s, 3 min 5 s.
    def test_duration(milliseconds)
      return "—" if milliseconds.nil?
      return t("member.project_tests.duration.ms", value: milliseconds) if milliseconds < 1_000

      seconds = milliseconds / 1000.0
      return t("member.project_tests.duration.s", value: number_with_precision(seconds, precision: 1)) if seconds < 60

      t("member.project_tests.duration.min", minutes: (seconds / 60).floor, seconds: (seconds % 60).round)
    end
  end
end
