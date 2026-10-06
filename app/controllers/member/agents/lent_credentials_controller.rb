# frozen_string_literal: true

module Member
  module Agents
    # A secret the organization lends to all its automator machines (CYAU-224 Claude, CYAU-228 OpenRouter).
    # Owner only: it is billed to the organization. Write-only: the field is never filled back, a new value
    # replaces. Every machine uses it, so a write is a confirmed, recorded dangerous action (CYRA-728).
    class LentCredentialsController < Member::BaseController
      class_attribute :credential_name, instance_writer: false

      before_action :require_owner
      before_action -> { require_permission!("agents.manage") }

      def show
        @credential = saved_credential
      end

      def update
        token = params[:token].to_s.strip
        return blank_token_outcome if token.blank?

        credential = saved_credential || current_organization.public_send(:"build_#{credential_name}")
        credential.assign_attributes(token: token, set_by: Current.account)
        return redirect_to(credential_path, notice: t("#{scope}.update.saved")) if credential.save

        # A rejected value is never written: the page shows the credential still saved.
        @credential = saved_credential(reload: true)
        @error = t("#{scope}.update.invalid")
        render :show, status: :unprocessable_content
      end

      def destroy
        saved_credential&.destroy
        redirect_to credential_path, notice: t("#{scope}.destroy.removed")
      end

      private

      def saved_credential(reload: false)
        current_organization.public_send(:"#{reload ? 'reload_' : ''}#{credential_name}")
      end

      def credential_path = public_send(:"member_agents_#{credential_name}_path")
      def scope = "member.#{credential_name}"

      # The field is never filled back, so blank means "untouched" when a credential is already saved.
      def blank_token_outcome
        return redirect_to(credential_path, notice: t("#{scope}.update.unchanged")) if saved_credential

        redirect_to credential_path, alert: t("#{scope}.update.missing")
      end

      # The confirmation page repeats the request in hidden fields: never with the secret in it.
      def repeatable_dangerous_params = nil

      def require_owner
        redirect_to(root_path, alert: t("member.forbidden")) unless current_membership&.owner?
      end
    end
  end
end
