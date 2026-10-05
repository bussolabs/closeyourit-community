# frozen_string_literal: true

module Member
  module SharedSecrets
    class VersionsController < Member::BaseController
      before_action { require_permission!("shared_secrets.manage") }

      def update
        variable = Current.organization.shared_secret_variables.find(params[:shared_secret_id])
        version = ::Secrets::Shared::Version.joins(:shared_value).where(secrets_shared_values: { shared_variable_id: variable.id }).find(params[:id])
        value = version.shared_value
        impact = ::Secrets::Shared::Impact.call(shared_value: value, effect: :rollback).value
        unless ActiveSupport::SecurityUtils.secure_compare(params[:confirmation_digest].to_s, impact["digest"])
          return redirect_to member_shared_secrets_path, alert: t("member.shared_secrets.stale")
        end
        result = ::Secrets::Shared::Save.call(organization: Current.organization, shared_variable: variable,
          name: variable.name, environment: value.environment, value: version.value, actor: Current.account,
          confirmation_digest: impact["digest"], confirmation_effect: :rollback, action: "rolled_back")
        redirect_to member_shared_secrets_path, **(result.ok? ? { notice: t("member.shared_secrets.rolled_back") } : { alert: result.error.message })
      end
    end
  end
end
