# frozen_string_literal: true

module Assistant
  module Proposals
    # Runs a proposal the user confirmed: re-checks visibility and permission now, then calls the
    # existing domain service (CYRA-907). Lock, effect and outcome share one transaction, so a crash
    # cannot leave an applied action marked as still running (CYRA-1017).
    # allowed_project_ids: the frozen scope of a Puck run, a ceiling on top of today's access.
    class Confirm < ApplicationService
      def initialize(proposal:, account:, organization:, true_actor: nil, allowed_project_ids: nil)
        @proposal = proposal
        @account = account
        @organization = organization
        @true_actor = true_actor
        @allowed_project_ids = allowed_project_ids
      end

      def call
        result = Assistant::Proposal.transaction do
          next err("R409-PROPOSAL-001", :not_confirmable) unless claim

          run.tap { |outcome| finish(outcome) }
        end
        result.ok? ? Result.ok(@proposal) : result
      end

      private

      # The row lock serializes confirmations: the second one finds the proposal no longer open.
      def claim
        locked = Assistant::Proposal.lock.find_by(id: @proposal.id, account_id: @account.id, organization_id: @organization.id)
        return false unless locked&.confirmable?

        @proposal = locked
      end

      # Text a Puck prepared says so, added here once whoever confirms it (CYRA-1023, CYRA-419).
      def signed(text)
        run = @proposal.coworkers_run
        return text if run.nil?

        "#{text}\n\n_#{I18n.t('member.coworkers.signature', name: run.puck.name)}_"
      end

      def ceiling_excludes?(project_id)
        @allowed_project_ids && !@allowed_project_ids.include?(project_id)
      end

      def run
        case @proposal.kind
        when "create_ticket" then create_ticket
        when "comment_ticket" then with_ticket(nil) { |t| Ticketing::AddComment.call(ticket: t, author: @account, params: { body: signed(payload["body"]) }) }
        when "change_ticket_status" then with_ticket("tickets.edit") { |t| change_status(t) }
        when "change_ticket_priority" then with_ticket("tickets.edit") { |t| change_priority(t) }
        when "assign_ticket" then with_ticket("tickets.assign") { |t| assign(t) }
        when "create_todo" then create_todo
        when "create_idea" then create_idea
        when "start_agent_work" then with_ticket("tickets.edit") { |t| start_agent_work(t) }
        when "external_tool" then external_tool
        end
      end

      def payload = @proposal.payload

      # A project no longer visible is the same refusal for every kind (CYRA-907).
      def not_visible_if(result, code)
        result.err? && result.error.code == code ? err("R404-PROPOSAL-001", :not_visible) : result
      end

      def create_ticket
        return err("R404-PROPOSAL-001", :not_visible) if ceiling_excludes?(payload["project_id"])

        not_visible_if(Ticketing::CreateTicket.call(
          organization: @organization, reporter: @account, true_actor: @true_actor,
          params: { project_id: payload["project_id"], title: payload["title"], description: signed(payload["description"]),
                    kind: payload["ticket_kind"], status_id: Ticketing::FormOptions.default_status_id(@organization),
                    priority_id: payload["priority_id"].presence || Ticketing::FormOptions.default_priority_id(@organization) }
        ), "R404-TICKET-001")
      end

      def with_ticket(permission)
        ticket = Ticketing::Ticket.where(project_id: visible.projects.select(:id)).find_by(id: payload["ticket_id"])
        return err("R404-PROPOSAL-001", :not_visible) if ticket.nil? || ceiling_excludes?(ticket.project_id)
        return err("R403-PROPOSAL-001", :forbidden) if permission && !resolver.can?(permission, scope: ticket.project)

        yield ticket
      end

      def change_status(ticket)
        Ticketing::ChangeStatus.call(organization: @organization, ticket: ticket, status_id: payload["status_id"],
                                     channel: :web, actor: @account, true_actor: @true_actor)
      end

      # UpdateTicket replaces every field it receives: send the current ones with the new priority.
      def change_priority(ticket)
        Ticketing::UpdateTicket.call(organization: @organization, ticket: ticket, channel: :web,
                                     actor: @account, true_actor: @true_actor,
                                     params: current_ticket_params(ticket).merge(priority_id: payload["priority_id"]))
      end

      def current_ticket_params(ticket)
        { title: ticket.title, kind: ticket.kind, description: ticket.description,
          technical_analysis: ticket.technical_analysis, weight: ticket.weight, due_at: ticket.due_at,
          parent_id: ticket.parent_id, platform_ids: ticket.platform_ids,
          status_id: ticket.status_id, assignee_id: ticket.assignee_id, milestone_id: ticket.milestone_id }
      end

      def assign(ticket)
        Ticketing::AssignTicket.call(organization: @organization, ticket: ticket, assignee_id: payload["assignee_id"],
                                     actor: @account, true_actor: @true_actor)
      end

      def create_todo
        list = Todos::List.for(account: @account, organization: @organization).find_by(id: payload["list_id"])
        return err("R404-PROPOSAL-001", :not_visible) if list.nil?

        Todos::Items::Save.call(item: list.items.build, attributes: { title: payload["title"] })
      end

      def create_idea
        return err("R404-PROPOSAL-001", :not_visible) if ceiling_excludes?(payload["project_id"])

        not_visible_if(Ideas::CreateIdea.call(organization: @organization, author: @account, true_actor: @true_actor,
                                              params: { project_id: payload["project_id"], title: payload["title"],
                                                        problem: signed(payload["problem"]) }), "R404-IDEA-001")
      end

      # The person lets the automation work the ticket; the agents open the pull request (CYRA-1028).
      def start_agent_work(ticket)
        result = Ticketing::SetAgentEligibility.call(ticket: ticket, source: :human, eligibility: "allowed",
                                                     reason: payload["note"].to_s.first(500).presence, actor: @account, true_actor: @true_actor)
        attach_proof_video(ticket) if result.ok?
        result
      end

      # The reproduction the Puck recorded goes on the ticket the automation will work (CYRA-1028).
      def attach_proof_video(ticket)
        video = @proposal.coworkers_run&.video
        return unless video&.attached?

        # The upload runs after this transaction commits: the copy must outlive the block.
        copy = Tempfile.new([ "proof", ".webm" ], binmode: true)
        copy.write(video.download)
        copy.rewind
        upload = ActionDispatch::Http::UploadedFile.new(tempfile: copy, filename: video.filename.to_s, type: "video/webm")
        Ticketing::AttachToTicket.call(ticket: ticket, files: [ upload ], actor: @account, true_actor: @true_actor)
      end

      # The call a Puck prepared in a connected app, made now with the app's stored token (CYRA-1014).
      def external_tool
        run = @proposal.coworkers_run
        connection = run&.puck&.connections&.find_by(id: payload["connection_id"])
        # A read-only connection runs only the tools it listed as reads.
        allowed = connection && (connection.write? || connection.tools.any? { |tool| tool["name"] == payload["tool"] && tool["read_only"] })
        return err("R404-PROPOSAL-001", :not_visible) if !allowed || !Coworkers::Apps.reachable?(run)

        outcome = Coworkers::Mcp.call_tool(connection, payload["tool"], payload["arguments"] || {})
        @proposal.payload = payload.merge("result" => outcome[:text].to_s.first(2000))
        outcome[:error] ? err("R502-PROPOSAL-001", :failed_external) : Result.ok(@proposal)
      rescue Coworkers::Mcp::Error
        err("R502-PROPOSAL-001", :failed_external)
      end

      def finish(result)
        if result.ok?
          record = result.value
          @proposal.update!(status: :confirmed, confirmed_at: Time.current, error_code: nil,
                            result_type: record.class.name, result_id: record.id)
        else
          @proposal.update!(status: :failed, error_code: result.error.code)
        end
      end

      def visible = @visible ||= Authorization::VisibleScope.new(account: @account, organization: @organization)
      def resolver = @resolver ||= Authorization::Resolver.new(account: @account, organization: @organization)

      def err(code, key)
        Result.err(AppError.new(I18n.t("member.assistant.proposals.errors.#{key}"), code: code,
                                status: code.start_with?("R409") ? :conflict : :unprocessable_content))
      end
    end
  end
end
