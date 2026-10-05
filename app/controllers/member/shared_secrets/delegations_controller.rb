# frozen_string_literal: true

module Member
  module SharedSecrets
    class DelegationsController < Member::BaseController
      before_action { require_permission!("shared_secrets.manage") }

      def create
        variable = Current.organization.shared_secret_variables.find(params[:shared_secret_id])
        value = variable.values.find(params[:value_id])
        project = Current.organization.projects.find(params[:project_id])
        result = ::Secrets::Shared::Delegate.call(shared_value: value, project:, actor: Current.account,
                                                  local_name: params[:local_name])
        redirect_to member_shared_secrets_path, **(result.ok? ? { notice: t("member.shared_secrets.delegated") } : { alert: result.error.message })
      end

      def destroy
        variable = Current.organization.shared_secret_variables.find(params[:shared_secret_id])
        delegation = variable.values.joins(:delegations).merge(::Secrets::Shared::Delegation.where(id: params[:id])).first!.delegations.find(params[:id])
        result = ::Secrets::Shared::Unlink.call(delegation:, actor: Current.account, confirmation_digest: params[:confirmation_digest])
        redirect_to member_shared_secrets_path, **(result.ok? ? { notice: t("member.shared_secrets.unlinked") } : { alert: t("member.shared_secrets.stale") })
      end
    end
  end
end
