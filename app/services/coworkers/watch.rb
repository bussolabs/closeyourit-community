module Coworkers
  # Unattended checks of a Puck's projects (CYRA-1011). Rails finds the new signals itself; the model
  # runs only when there is something new, and its proposals always wait for a person.
  module Watch
    Signal = Data.define(:key, :text)
    MAX_REPORTED = 500
    MAX_SIGNALS = 10

    # Oldest first and without what was already reported, one signal more than a check takes: that one
    # says a burst goes on, so the window stays where it is and nothing beyond the tenth is lost.
    def self.signals(puck, since:)
      project_ids = Scope.capture(account: puck.account, organization: puck.organization, puck: puck)["project_ids"]
      reported = puck.watch_state.fetch("reported", {}).keys
      (new_errors(project_ids, since, reported) + open_incidents(project_ids, since, reported)).first(MAX_SIGNALS + 1)
    end

    def self.new_errors(project_ids, since, reported)
      Errors::Group.status_unresolved.where(project_id: project_ids).where(first_seen_at: since..)
                   .where.not(id: reported_ids(reported, "error_group"))
                   .includes(:project).order(:first_seen_at, :id).limit(MAX_SIGNALS + 1)
                   .map { |group| Signal.new(key: "error_group:#{group.id}", text: "#{group.project.key}: new error \"#{group.title}\"") }
    end

    def self.open_incidents(project_ids, since, reported)
      Uptime::Incident.open.top_level.joins(:monitor).where(uptime_monitors: { project_id: project_ids })
                      .where(started_at: since..).where.not(id: reported_ids(reported, "uptime_incident"))
                      .includes(monitor: :project).order(:started_at, :id).limit(MAX_SIGNALS + 1)
                      .map { |incident| Signal.new(key: "uptime_incident:#{incident.id}", text: "#{incident.monitor.project.key}: monitor down since #{incident.started_at.utc.iso8601}") }
    end

    def self.reported_ids(keys, kind) = keys.filter_map { |key| key.delete_prefix("#{kind}:") if key.start_with?("#{kind}:") }

    # One check of one Puck: start a watch run when there is news, then plan the next check.
    def self.check(puck, at: Time.current)
      since = Time.zone.parse(puck.watch_state["since"].to_s) || 1.day.ago
      pending = signals(puck, since: since)
      found = pending.first(MAX_SIGNALS)
      Start.call(puck: puck, kind: "watch", input: prompt(found)) if found.any?
      remember(puck, found, at, more: pending.size > MAX_SIGNALS)
    rescue Start::Busy, Start::OverBudget
      puck.update_columns(watch_next_at: at + 1.minute)
    end

    def self.remember(puck, found, at, more:)
      reported_at = at.utc.iso8601
      reported = puck.watch_state.fetch("reported", {}).merge(found.to_h { |signal| [ signal.key, reported_at ] })
      reported = reported.sort_by { |_key, time| time }.last(MAX_REPORTED).to_h
      since = more ? puck.watch_state["since"].presence || 1.day.ago.utc.iso8601 : at.utc.iso8601
      # update_columns: the lock version guards memory edits, and a check must not invalidate them.
      puck.update_columns(watch_state: { "since" => since, "reported" => reported },
                          watch_next_at: at + (more ? 1.minute : puck.watch_every_minutes.minutes))
    end

    def self.prompt(found)
      "Automatic check. New signals in your projects:\n" + found.map { |signal| "- #{signal.text} [#{signal.key}]" }.join("\n") +
        "\nStudy them with your tools, say what matters and propose the next step. Proposals wait for a person."
    end
    private_class_method :new_errors, :open_incidents, :reported_ids, :remember, :prompt
  end
end
