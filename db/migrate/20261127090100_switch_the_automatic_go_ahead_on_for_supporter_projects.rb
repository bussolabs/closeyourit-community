# frozen_string_literal: true

# CYRA-1219 — the automatic go-ahead goes on where the supporter is on, except LegalBloom (its lead chose so
# on 2026-11-26), and the tickets the old supporter held on a contrary advice wait for a person again.
# Each reopened ticket gets a history entry that keeps what it held: `down` reads those entries back.
class SwitchTheAutomaticGoAheadOnForSupporterProjects < ActiveRecord::Migration[8.1]
  MARK = "cyra_1219_rollout"
  EXCLUDED_NAME = "legalbloom"
  EXHAUSTED_BUDGET_MARK = "exhausted_budget:"
  # Raw enum integers of Ticketing::Ticket: pending 0, blocked 2; source automatic 0.
  PENDING = 0
  BLOCKED = 2
  AUTOMATIC = 0

  class Project < ActiveRecord::Base
    self.table_name = "projects"
  end

  class Ticket < ActiveRecord::Base
    self.table_name = "ticketing_tickets"
  end

  class Event < ActiveRecord::Base
    self.table_name = "ticketing_events"
  end

  class StoppedWithoutLegalBloom < StandardError; end

  def up
    switch_projects_on
    reopen_held_tickets
  end

  # The switch did not exist before this migration: off is where every project started (plan R-4).
  def down
    restore_held_tickets
    execute("UPDATE projects SET auto_go_ahead_enabled = FALSE WHERE auto_go_ahead_enabled = TRUE")
  end

  def switch_projects_on
    excluded = excluded_projects
    if excluded.empty? && real_production?
      raise StoppedWithoutLegalBloom, "no LegalBloom project found: the automatic go-ahead was not switched on"
    end

    say("left off (LegalBloom): #{excluded.map { |project| project.key || project.name }.join(", ").presence || "none"}")
    Project.where(supporter_enabled: true, auto_go_ahead_enabled: false).where.not(id: excluded.map(&:id))
           .update_all(auto_go_ahead_enabled: true, updated_at: Time.current)
  end

  # CYRA-1365 — the staging server runs with the production environment too, and has no LegalBloom project:
  # stopping there kept the application from starting. Only its host name tells it apart.
  def real_production?
    Rails.env.production? && !ENV.fetch("APP_HOSTS", "").include?(".staging.")
  end

  # A group or a project whose name, letters only, reads «legalbloom».
  def excluded_projects
    normalized = ->(column) { "regexp_replace(lower(#{column}), '[^a-z]', '', 'g') LIKE '%#{EXCLUDED_NAME}%'" }
    Project.joins("LEFT JOIN projects_groups ON projects_groups.id = projects.group_id")
           .where("#{normalized.call("projects.name")} OR #{normalized.call("projects_groups.name")}")
           .select(:id, :key, :name).to_a
  end

  def reopen_held_tickets
    held_on_contrary_advice.find_each do |ticket|
      Ticket.transaction do
        locked = held_on_contrary_advice.lock.find_by(id: ticket.id)
        next if locked.nil?

        record(locked)
        locked.update_columns(agent_eligibility: PENDING, agent_eligibility_reason: nil,
                              agent_eligibility_decided_at: nil, agent_eligibility_decided_by_id: nil)
      end
    end
  end

  # Only what the old supporter wrote: blocked, automatic, the reason equal to the contrary advice, and
  # never a ticket set aside because its attempts ran out.
  def held_on_contrary_advice
    exhausted = "SELECT 1 FROM agents_workflows WHERE agents_workflows.ticket_id = ticketing_tickets.id " \
                "AND agents_workflows.cancelled_by_id IS NULL AND agents_workflows.cancellation_reason LIKE " \
                "'#{EXHAUSTED_BUDGET_MARK}%'"
    Ticket.where(agent_eligibility: BLOCKED, agent_eligibility_source: AUTOMATIC, agent_eligibility_advice: BLOCKED)
          .where("ticketing_tickets.agent_eligibility_reason = ticketing_tickets.agent_eligibility_advice_reason")
          .where("NOT EXISTS (#{exhausted})")
  end

  def record(ticket)
    now = Time.current
    organization_id = Project.where(id: ticket.project_id).pick(:organization_id)
    Event.create!(ticket_id: ticket.id, organization_id:, action: "agent_eligibility_overridden",
                  actor_name: "Supporter", created_at: now, updated_at: now,
                  data: { go_ahead: "rollout_reopened", rollout: MARK,
                          agent_eligibility: { from: "blocked", to: "pending" },
                          held_reason: ticket.agent_eligibility_reason,
                          held_decided_at: ticket.agent_eligibility_decided_at&.iso8601(6) })
  end

  # Back to held only where nothing has moved since: still pending and automatic. A ticket a person decided,
  # or one the new advice opened, keeps what it has now.
  def restore_held_tickets
    Event.where(action: "agent_eligibility_overridden").where("data->>'rollout' = ?", MARK).find_each do |event|
      Ticket.transaction do
        ticket = Ticket.lock.find_by(id: event.ticket_id, agent_eligibility: PENDING, agent_eligibility_source: AUTOMATIC)
        if ticket
          ticket.update_columns(agent_eligibility: BLOCKED, agent_eligibility_reason: event.data["held_reason"],
                                agent_eligibility_decided_at: event.data["held_decided_at"])
        end
        event.destroy!
      end
    end
  end
end
