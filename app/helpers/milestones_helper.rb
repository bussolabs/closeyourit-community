# frozen_string_literal: true

# Due date of a milestone: short date, time left, and a colour when it is close or past.
module MilestonesHelper
  MILESTONE_DUE_COLORS = { late: :red, soon: :amber, on_time: :gray }.freeze

  # :late / :soon / :on_time, nil without a due date. An inactive milestone never alarms.
  def milestone_due_state(milestone, today: Date.current)
    return if milestone.due_on.nil?
    return :on_time unless milestone.active?
    return :late if milestone.due_on < today

    milestone.due_on <= today + Projects::Constants::MILESTONE_DUE_SOON_DAYS ? :soon : :on_time
  end

  # "21 ott", with the year only when it is not this year.
  def milestone_short_date(date, today: Date.current)
    l(date, format: date.year == today.year ? :day_month : :day_month_year)
  end

  # "tra 20 giorni" / "oggi" / "3 giorni fa".
  def milestone_due_relative(date, today: Date.current)
    days = (date - today).to_i
    return t("member.milestones.due_today") if days.zero?

    days.positive? ? t("member.milestones.due_in", count: days) : t("member.milestones.due_ago", count: -days)
  end
end
