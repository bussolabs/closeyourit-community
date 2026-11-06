# frozen_string_literal: true

module Agents
  module Supporters
    # CYRA-1197 — the stopped workflow a machine's supporter should look at next: blocked by a machine (not by a
    # person, not by a safety stop), on an open ticket of a project of the machine's organization with the supporter on, not yet
    # judged at this stop, and with retries left. The digest pins the stop it read: a verdict on a workflow that
    # moved meanwhile is refused.
    class NextConsult < ApplicationService
      # A red proposal already had its fix round (CYRA-1195), and a held release waits for the person who held it.
      CONSULTABLE_KINDS = %w[agent_blocked attempt_limit release_probe].freeze
      MAX_RETRIES = 2
      ATTEMPTS_SHOWN = 3
      TEXT_LIMIT = 800
      STALE_REASON = "stale: the machine lost this attempt (restart or lease timeout) before it reported; " \
                     "nothing came back from the work itself"

      # Bumped when what the supporter reads about a stop changes, so stops judged on the old record are read again.
      DIGEST_VERSION = 2

      def self.digest(workflow)
        "sha256:" + Digest::SHA256.hexdigest(JSON.generate([ DIGEST_VERSION, workflow.id, workflow.blocked_at&.to_i,
                                                             workflow.blocked_kind, workflow.blocked_reason ]))
      end

      # What the supporter reads about the stop: the reason and the last attempts on the stopped phase.
      def self.stop(workflow)
        attempts = workflow.attempts.where(phase: workflow.blocked_phase).order(created_at: :desc).limit(ATTEMPTS_SHOWN)
        { kind: workflow.blocked_kind, phase: workflow.blocked_phase, reason: workflow.blocked_reason.to_s.truncate(TEXT_LIMIT),
          attempts: attempts.map { |attempt| attempt_summary(attempt) } }
      end

      def self.attempt_summary(attempt)
        findings = Array(attempt.review&.dig("findings")).filter_map do |finding|
          next unless finding.is_a?(Hash) && finding["severity"].present? && finding["severity"] != "info"

          "#{finding["severity"]}: #{finding["title"]} #{finding["detail"]}".squish.truncate(300)
        end.first(5)
        { status: attempt.status, failure_reason: failure_reason(attempt), review_findings: findings,
          review_summary: attempt.review.is_a?(Hash) ? attempt.review["summary"].to_s.truncate(TEXT_LIMIT) : "",
          summary: attempt.result.is_a?(Hash) ? attempt.result["summary"].to_s.truncate(TEXT_LIMIT) : "" }
      end

      # A stale attempt leaves no reason of its own: the machine lost it (restart, lease timeout), not the work.
      def self.failure_reason(attempt)
        return attempt.failure_reason.to_s.truncate(TEXT_LIMIT) if attempt.failure_reason.present?

        attempt.status == "stale" ? STALE_REASON : ""
      end

      def initialize(host:)
        @host = host
      end

      # Every stopped workflow, oldest stop first: two queries whatever the backlog.
      def call
        workflows = candidates.to_a
        decisions = SupporterDecision.where(target_type: "consult", workflow_id: workflows.map(&:id))
                                     .pluck(:workflow_id, :target_digest, :outcome)
        judged = decisions.to_set { |workflow_id, digest, _| [ workflow_id, digest ] }
        retries = decisions.select { |_, _, outcome| outcome == "retried" }.map(&:first).tally
        workflows.each do |workflow|
          next if retries.fetch(workflow.id, 0) >= MAX_RETRIES

          digest = self.class.digest(workflow)
          return Result.ok(item(workflow, digest)) unless judged.include?([ workflow.id, digest ])
        end
        Result.ok(nil)
      end

      private

      def candidates
        Agents::Workflow.joins(ticket: :project)
          .where(cancelled_at: nil, completed_at: nil, blocked_kind: CONSULTABLE_KINDS)
          .where.not(blocked_at: nil)
          .where.not(Ticketing::Ticket.table_name => { status_id: Types::TicketStatus.category_done.select(:id) })
          .where(projects: { organization_id: @host.organization_id, supporter_enabled: true })
          .where(FollowedProjects.condition(@host))
          .includes(ticket: :project).order(:blocked_at, :id)
      end

      # OpenCode judges with the organization's OpenRouter model, like it reviews.
      def model = (Agents::AutomatorSetting.for(@host.organization).opencode_model if @host.effective_supporter == "opencode")

      def item(workflow, digest)
        ticket = workflow.ticket
        { workflow_id: workflow.id, digest: digest, engine: @host.effective_supporter, project_key: ticket.project.key,
          ticket: { code: ticket.code, title: ticket.title, description: ticket.description.to_s },
          stop: self.class.stop(workflow), autonomous_max: RiskScore::AUTONOMOUS_MAX, model: model }
      end
    end
  end
end
