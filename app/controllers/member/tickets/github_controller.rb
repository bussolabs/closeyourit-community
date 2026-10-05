# frozen_string_literal: true

module Member
  module Tickets
    # Azioni GitHub dal ticket (Fase 2): crea branch / apre PR (identità bot dell'App). Il ticket è
    # risolto con la visibilità Fase E (visible.tickets → 404 anti-BOLA); gate github.manage sul
    # progetto del ticket. La logica vive nei service condivisi Ticketing::Github::* (rules/backend-channels.md).
    class GithubController < Member::BaseController
      before_action :set_ticket
      before_action :require_manage

      def branch
        result = Ticketing::Github::CreateBranch.call(
          ticket: @ticket, actor: Current.account, true_actor: Current.true_account
        )
        respond_with_result(result, t("member.tickets.github.branch_created"))
      end

      def pull_request
        result = Ticketing::Github::OpenPullRequest.call(
          ticket: @ticket, actor: Current.account, true_actor: Current.true_account
        )
        respond_with_result(result, t("member.tickets.github.pull_request_opened"))
      end

      private

      def respond_with_result(result, notice)
        if result.ok?
          redirect_to member_ticket_path(@ticket), notice: notice
        else
          redirect_to member_ticket_path(@ticket), alert: result.error.message
        end
      end

      def set_ticket
        @ticket = visible.tickets.find(params[:ticket_id])
      end

      def require_manage
        require_permission!("github.manage", scope: @ticket.project)
      end
    end
  end
end
