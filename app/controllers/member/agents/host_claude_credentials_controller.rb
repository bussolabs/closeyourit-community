# frozen_string_literal: true

module Member
  module Agents
    # CYRA-1052 — one machine's own Claude credential, served before the organization's. Owner only, like
    # the organization's: it is billed to whoever lends it. Write-only: the field is never filled back.
    class HostClaudeCredentialsController < Member::BaseController
      before_action :require_owner
      before_action -> { require_permission!("agents.manage") }
      before_action :set_host

      def update
        if params[:secret].blank? && params[:token].to_s.strip.blank?
          return redirect_to(details_path, notice: t("member.claude_credential.update.unchanged"))
        end

        result = ::Agents::ClaudeCredentials::Save.call(organization: current_organization, host: @host,
                                                        actor: Current.account, token: params[:token],
                                                        secret: params[:secret])
        if result.ok?
          redirect_to details_path, notice: t("member.agents.claude.saved")
        else
          redirect_to details_path, alert: t("member.claude_credential.update.invalid")
        end
      end

      def destroy
        @host.claude_credential&.destroy
        redirect_to details_path, notice: t("member.agents.claude.removed")
      end

      private

      def set_host
        @host = current_organization.agent_hosts.find(params[:agent_id])
      end

      def details_path = member_agent_path(@host, tab: "details")

      # The confirmation page repeats the request in hidden fields: never with the secret in it.
      def repeatable_dangerous_params = nil

      def require_owner
        redirect_to(root_path, alert: t("member.forbidden")) unless current_membership&.owner?
      end
    end
  end
end
