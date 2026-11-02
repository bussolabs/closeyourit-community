# frozen_string_literal: true

module Agents
  module Council
    # Closes a council slice: judges the votes, drops duplicates, respects the open-ticket cap and the mode,
    # then opens tickets or ideas (CYRA-1133). The model output decides nothing the fixed rules do not allow.
    class Settle < ApplicationService
      DESCRIPTION_MAX = 4000

      def initialize(host:, run_id:, payload:)
        @host = host
        @run_id = run_id
        @payload = payload.to_h.deep_stringify_keys
        @dry_tickets = 0
      end

      def call
        return error("R404-COUNCIL-001", :not_found) if run.nil?
        return error("R409-COUNCIL-001", :closed) unless run.status == "running"
        return fail_run! if @payload["failure"].is_a?(Hash)

        report = Judge.call(proposals: @payload["proposals"], critiques: @payload["critiques"])
                      .map { |verdict| settle_one(verdict) }.tally
        run.update!(status: "completed", finished_at: Time.current, report: { "outcomes" => report })
        Result.ok({ status: "completed", outcomes: report })
      end

      private

      def run
        @run ||= CouncilRun.find_by(id: @run_id, organization_id: @host.organization_id)
      end

      def project = run.project
      def author = @host.service_account

      def fail_run!
        failure = @payload["failure"]
        kind = failure["kind"].presence_in(CouncilRun::FAILURE_KINDS) || "session"
        run.update!(status: "failed", failure_kind: kind, failure: failure["detail"].to_s.truncate(500),
                    finished_at: Time.current)
        Result.ok({ status: "failed", outcomes: {} })
      end

      def settle_one(verdict)
        record = build_record(verdict)
        record.outcome = outcome_for(verdict, record)
        record.reasons = verdict.reasons
        record.save!
        record.outcome
      end

      def outcome_for(verdict, record)
        return decide(record) if verdict.passed

        verdict.reasons == [ "invalid" ] ? "invalid" : "rejected"
      end

      def build_record(verdict)
        p = verdict.proposal
        CouncilProposal.new(
          council_run: run, organization: run.organization, project:, ref: p["ref"].to_s, proposer: p["proposer"],
          title: p["title"].presence || "-", problem: p["problem"].presence || "-", solution: p["solution"],
          kind: p["kind"], risk: p["risk"], suggested_engine: p["engine"], suggested_model: p["model"],
          critique: verdict.critique || {}, outcome: "rejected"
        )
      end

      def decide(record)
        duplicate = duplicate?(record)
        return "unchecked" if duplicate.nil?
        return "duplicate" if duplicate
        return dry_outcome if run.mode == "dry_run"

        room_left? ? open_ticket(record) : open_idea(record)
      end

      # A dry run counts the tickets it would have opened, so the cap reads the same as when on.
      def dry_outcome
        return "dry_idea" unless room_left?

        @dry_tickets += 1
        "dry_ticket"
      end

      # nil when the check could not run: without it the council creates nothing.
      def duplicate?(record)
        text = [ record.title, record.problem ].join("\n")
        tickets = Ticketing::FindSimilarTickets.call(scope: unfinished(project.tickets), text:,
                                                     min_similarity: Ticketing::Constants::DUPLICATE_GATE_SIMILARITY)
        ideas = Ideas::FindSimilarIdeas.call(scope: project.ideas.status_open, text:)
        return nil if tickets.err? || ideas.err?

        tickets.value.any? || ideas.value.any?
      end

      def unfinished(scope)
        categories = Types::TicketStatus.categories
        scope.joins(:status).where(types_ticket_statuses: { category: [ categories[:open], categories[:in_progress] ] })
      end

      def room_left?
        ids = CouncilProposal.ticket_ids_for(run.organization)
        unfinished(Ticketing::Ticket.where(id: ids)).count + @dry_tickets < OPEN_TICKET_CAP
      end

      def open_ticket(record)
        result = Ticketing::CreateTicket.call(
          organization: run.organization, reporter: author,
          params: ticket_params(record)
        )
        return "create_failed" if result.err?

        record.ticket = result.value
        "ticket"
      end

      def ticket_params(record)
        organization = run.organization
        { project_id: project.id, title: record.title, kind: TICKET_KINDS.fetch(record.kind, "task"),
          description: ticket_body(record),
          status_id: Ticketing::FormOptions.default_status_id(organization),
          priority_id: Ticketing::FormOptions.default_priority_id(organization) }
      end

      def open_idea(record)
        result = Ideas::CreateIdea.call(
          organization: run.organization, author:,
          params: { project_id: project.id, title: record.title, problem: record.problem,
                    solution: record.solution, risks: record.risk }
        )
        return "create_failed" if result.err?

        record.idea = result.value
        "idea"
      end

      def ticket_body(record)
        critique = record.critique
        I18n.t("agents.council.ticket_body",
               problem: record.problem, solution: record.solution.presence || "-", risk: record.risk || "-",
               proposer: record.proposer, critic: critique["critic"], vote: critique["vote"],
               critic_risk: critique["risk"] || "-", reason: critique["reason"].to_s,
               engine: record.suggested_engine || I18n.t("agents.council.engine_default"),
               model: record.suggested_model.to_s).truncate(DESCRIPTION_MAX)
      end

      def error(code, key)
        status = { "R404" => :not_found, "R409" => :conflict }.fetch(code[0, 4])
        Result.err(AppError.new(I18n.t("agents.council.errors.#{key}"), code:, status:))
      end
    end
  end
end
