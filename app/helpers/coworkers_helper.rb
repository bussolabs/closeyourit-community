module CoworkersHelper
  # What happened to an action a Puck proposed, as the key of its one-line outcome (CYRA-1017).
  def coworker_action_outcome(proposal)
    return "pending" if proposal.status_pending? || proposal.status_running?
    return "failed" if proposal.status_failed?

    origin = proposal.origin == "rule" || proposal.error_code == "R403-COWORKERS-002" ? "rule" : "user"
    "#{proposal.status_confirmed? ? 'confirmed' : 'discarded'}_#{origin}"
  end

  # "Every weekday at 08:00 · next: 7 Oct 08:00 (Europe/Rome)" (CYRA-1001).
  def coworker_schedule_summary(schedule)
    when_text = t("member.coworkers.schedules.every.#{schedule.frequency}", time: format("%02d:%02d", schedule.hour, schedule.minute),
                  minute: format("%02d", schedule.minute), day: t("date.day_names")[schedule.weekday.to_i])
    return "#{when_text} · #{t('member.coworkers.schedules.paused')}" if schedule.paused?

    "#{when_text} · #{t('member.coworkers.schedules.next', at: l(schedule.next_run_at.in_time_zone(schedule.time_zone), format: '%-d %b %H:%M'))} (#{schedule.time_zone})"
  end

  # The owner's quiet-hours zone when set, otherwise the application's.
  def coworker_default_time_zone
    Alerting::Preference.for(account: Current.account, organization: Current.organization).quiet_hours_tz.presence || Time.zone.tzinfo.name
  end
end
