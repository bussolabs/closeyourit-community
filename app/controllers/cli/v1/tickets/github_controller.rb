# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # Azioni GitHub dal ticket via CLI (Fase 2): `cyi tickets branch` / `cyi tickets pr`. Ticket
      # risolto per code/UUID (find_ticket!), gate github.manage sul progetto. Parità col canale Member
      # via i service condivisi Ticketing::Github::* (rules/backend-channels.md). Envelope {data}/{error}.
      class GithubController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_ticket
        before_action -> { require_permission!("github.manage", scope: @project) }

        def branch
          respond Ticketing::Github::CreateBranch.call(ticket: @ticket, actor: Current.account)
        end

        def pull_request
          respond Ticketing::Github::OpenPullRequest.call(ticket: @ticket, actor: Current.account)
        end

        private

        def respond(result)
          if result.err?
            return render_error(result.error.code, result.error.message,
                                status: result.error.status, details: result.error.details)
          end

          render_ok(payload_for(result.value))
        end

        def payload_for(record)
          case record
          when ::Github::Branch
            { kind: "branch", name: record.name, html_url: record.html_url, ticket_id: record.ticket_id }
          when ::Github::PullRequest
            { kind: "pull_request", number: record.number, state: record.state,
              html_url: record.html_url, ticket_id: record.ticket_id }
          end
        end

        def set_ticket
          @ticket = find_ticket!(@project, params[:ticket_id])
        end
      end
    end
  end
end
