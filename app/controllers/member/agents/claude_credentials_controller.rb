# frozen_string_literal: true

module Member
  module Agents
    # The Claude credential the organization lends to its automator machines (CYAU-224). CYRA-1052: pasted
    # or linked from a vault secret.
    class ClaudeCredentialsController < LentCredentialsController
      self.credential_name = :claude_credential

      def show
        super
        @secret_options = secret_options
      end

      def update
        return super if params[:secret].blank? && params[:token].to_s.strip.blank?

        result = ::Agents::ClaudeCredentials::Save.call(organization: current_organization, actor: Current.account,
                                                        token: params[:token], secret: params[:secret])
        return redirect_to(credential_path, notice: t("#{scope}.update.saved")) if result.ok?

        @credential = saved_credential(reload: true)
        @secret_options = secret_options
        @error = t("#{scope}.update.invalid")
        render :show, status: :unprocessable_content
      end

      private

      def secret_options
        ::Agents::ClaudeCredentials::SecretOptions.call(organization: current_organization, account: Current.account)
      end
    end
  end
end
