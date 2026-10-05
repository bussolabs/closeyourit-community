# frozen_string_literal: true

module Cli
  module V1
    # Organization-scoped membership management, with protected owner/god targets.
    # Accounts::Update permits display changes but rejects global recovery email changes.
    class MembersController < Cli::V1::BaseController
      before_action -> { require_permission!("members.view") unless authorization.can?("members.manage") },
                    only: :index
      before_action :set_membership, only: %i[update destroy]
      before_action -> { require_permission!("members.edit") }, only: :update
      before_action :forbid_protected_target!, only: :update
      before_action -> { require_permission!("members.manage") }, only: :destroy

      def index
        scope = Current.organization.memberships.includes(:account).references(:account).order("accounts.email")
        records, meta = paginate(scope)
        render_ok(MemberSerializer.new(records), meta: meta)
      end

      # Keep email in the input so attempted identity changes receive an explicit error.
      def update
        result = ::Accounts::Update.call(account: @membership.account, attributes: account_params)
        if result.ok?
          render_ok(MemberSerializer.new(@membership.reload))
        else
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end

      def destroy
        result = ::Connections::RemoveMember.call(membership: @membership)
        if result.ok?
          render_no_content
        else
          render_error(result.error.code, result.error.message, status: result.error.status)
        end
      end

      private

      # Anti-BOLA: membership dentro l'org corrente → id di altra org → R404 (prima del gate).
      def set_membership
        @membership = Current.organization.memberships.find(params[:id])
      end

      def account_params
        params.permit(:name, :email, :handle)
      end

      # email/handle sono credenziali GLOBALI: un attore NON privilegiato (né owner né god) non può
      # modificare l'anagrafica di un target protetto (owner dell'org o account god) → anti-escalation
      # (takeover via password reset). Owner/god editano chiunque. Specchio di Member::MembersController.
      def forbid_protected_target!
        return if actor_privileged?
        return unless @membership.owner? || @membership.account.god?

        Rails.logger.warn(
          "Protected member edit denied (CLI) — account=#{Current.account&.id} " \
          "org=#{Current.organization&.id} target=#{@membership.id}"
        )
        render_error("R403-CLIAUTH-002", "Permesso negato", status: :forbidden)
      end

      # Privilegiato = owner dell'org o god (stessa nozione di VisibleScope.unscoped?).
      def actor_privileged?
        Authorization::VisibleScope.unscoped?(account: Current.account, organization: Current.organization)
      end
    end
  end
end
