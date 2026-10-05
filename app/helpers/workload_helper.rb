# frozen_string_literal: true

module WorkloadHelper
  # Colore (palette Ui::Colors::SWATCH + Ui::BadgeComponent) per lo stato di una Workload::Action.
  # Allineato al linguaggio cromatico della board Tickets (open→amber, in_progress→indigo,
  # resolved→emerald, closed→gray) così le due board sono visivamente coerenti.
  WORKLOAD_STATUS_COLORS = {
    "planned" => :amber,
    "in_progress" => :indigo,
    "done" => :emerald,
    "cancelled" => :gray
  }.freeze

  def workload_status_color(status)
    WORKLOAD_STATUS_COLORS.fetch(status.to_s, :gray)
  end

  # Badge colour for each due state: the same thresholds as the workload_due_soon reminder.
  WORKLOAD_DUE_COLORS = { late: :red, soon: :amber, on_time: :gray }.freeze

  # :late / :soon / :on_time, nil without a due date. A closed action never alarms.
  def workload_due_state(action, now: Time.current)
    return if action.due_at.nil?
    return :on_time unless action.status_planned? || action.status_in_progress?
    return :late if action.due_at < now

    action.due_at <= now + Workload::Constants::DUE_SOON_THRESHOLD ? :soon : :on_time
  end

  # "12 mar" / "Mar 12": through the locale formats, so the month follows the language.
  def workload_short_date(time)
    time && l(time.to_date, format: :day_month)
  end
end
