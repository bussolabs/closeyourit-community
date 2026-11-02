# app/services/agents/council/next_slice.rb
# frozen_string_literal: true

module Agents
  module Council
    # The next project the council should look at, and the data it reads (CYRA-1133). One slice at a time
    # per organization; each project at most once a day; the least recently seen goes first.
    class NextSlice < ApplicationService
      SIGNAL_LIMIT = 10
      OPEN_LIMIT = 50

      def initialize(host:, now: Time.current)
        @host = host
        @organization = host.organization
        @now = now
      end

      def call
        return Result.ok(nil) if setting.council_mode == "off" || @host.service_account.nil?

        abandon_stale!
        return Result.ok(nil) if busy?

        project = next_project
        return Result.ok(nil) if project.nil?

        run = CouncilRun.create!(organization: @organization, project:, host: @host, mode: setting.council_mode,
                                 status: "running", started_at: @now)
        Result.ok(payload(run))
      rescue ActiveRecord::RecordNotUnique
        Result.ok(nil) # another machine took the organization's only running slice
      end

      private

      def setting = @setting ||= AutomatorSetting.for(@organization)
      def runs = CouncilRun.where(organization: @organization)

      def abandon_stale!
        runs.running.where(started_at: ..(@now - RUN_STALE_AFTER))
            .update_all(status: "failed", failure_kind: "abandoned", finished_at: @now, updated_at: @now)
      end

      def busy?
        runs.running.exists? ||
          runs.where(status: "failed", failure_kind: "quota", started_at: (@now - RUN_INTERVAL)..).exists?
      end

      def next_project
        candidates = Authorization::VisibleScope.new(account: @host.service_account, organization: @organization)
                                                .projects.council_active.to_a
        last_seen = runs.where(project_id: candidates.map(&:id)).group(:project_id).maximum(:started_at)
        candidates.reject { |p| last_seen[p.id]&.after?(@now - RUN_INTERVAL) }
                  .min_by { |p| [ last_seen[p.id] || Time.zone.at(0), p.created_at ] }
      end

      def payload(run)
        project = run.project
        { run_id: run.id, project_key: project.key, mode: run.mode, max_proposals: MAX_PROPOSALS_PER_ENGINE,
          engines: ENGINES, models: MODELS, kinds: KINDS, risks: RISKS,
          signals: { errors: errors(project), slow: slow(project), monitors_down: monitors_down(project) },
          open_tickets: open_tickets(project), open_ideas: open_ideas(project) }
      end

      def errors(project)
        project.error_groups.status_unresolved.order(events_count: :desc).limit(SIGNAL_LIMIT)
               .map { |g| { title: g.title, culprit: g.culprit, events: g.events_count, last_seen_at: g.last_seen_at } }
      end

      def slow(project)
        project.metric_groups.status_unresolved.order(duration_total_ms: :desc).limit(SIGNAL_LIMIT)
               .map { |g| { title: g.title, kind: g.kind, samples: g.samples_count, max_ms: g.duration_max_ms } }
      end

      def monitors_down(project) = project.uptime_monitors.status_down.limit(SIGNAL_LIMIT).map { |m| { name: m.name } }

      def open_tickets(project)
        project.tickets.where.not(status_id: ::Types::TicketStatus.category_done.select(:id))
               .order(created_at: :desc).limit(OPEN_LIMIT).map { |t| { code: t.code, title: t.title } }
      end

      def open_ideas(project)
        project.ideas.where(status: :open).order(created_at: :desc).limit(OPEN_LIMIT).map { |i| { title: i.title } }
      end
    end
  end
end
