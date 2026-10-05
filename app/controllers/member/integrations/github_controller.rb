# frozen_string_literal: true

module Member
  module Integrations
    # Installazione della GitHub App a livello ORGANIZZAZIONE (1:1). `show` mostra lo stato + il link di
    # installazione su GitHub; `callback` è il redirect di GitHub dopo l'installazione
    # (?installation_id=…&setup_action=install) e registra l'installazione (il login dell'org si legge
    # dall'API, GitHub non lo passa nel redirect). Gate organization.manage.
    class GithubController < Member::BaseController
      FLOW_TTL = 10.minutes
      before_action :require_org_manage

      def show
        @installation = Current.organization.github_installation
        # CYRA-581 — quanti repo pendono da questa installazione: è il numero che dice cosa si porta
        # via la disinstallazione, e sta in cima insieme allo stato.
        @repositories_count = @installation&.repositories&.count.to_i
        @install_url = install_url
      end

      def callback
        flow = session.delete(:github_installation_flow)&.with_indifferent_access
        return failed_callback unless valid_flow?(flow) && configured? && params[:error].blank? && params[:setup_action] != "cancel"

        if flow[:installation_id].blank?
          return failed_callback unless params[:installation_id].to_s.match?(/\A[1-9]\d*\z/)

          state = start_flow(installation_id: params[:installation_id])
          query = URI.encode_www_form(client_id: Settings::Integrations.value(:gh_app_client_id), state:,
                                      redirect_uri: callback_member_integrations_github_url)
          return redirect_to("https://github.com/login/oauth/authorize?#{query}", allow_other_host: true)
        end

        result = ::Github::Installations::Connect.call(
          organization: Current.organization, installation_id: flow[:installation_id],
          code: params[:code], redirect_uri: callback_member_integrations_github_url
        )
        return failed_callback if result.err?

        redirect_to member_integrations_github_path, notice: t("member.integrations.github.connected")
      end

      def destroy
        Current.organization.github_installation&.destroy
        redirect_to member_integrations_github_path, notice: t("member.integrations.github.disconnected")
      end

      private

      def start_flow(installation_id: nil)
        state = SecureRandom.urlsafe_base64(32)
        session[:github_installation_flow] = {
          state:, account_id: Current.account.id, organization_id: Current.organization.id,
          installation_id:, expires_at: FLOW_TTL.from_now.to_i
        }
        state
      end

      def valid_flow?(flow)
        flow && flow[:account_id] == Current.account.id && flow[:organization_id] == Current.organization.id &&
          flow[:expires_at].to_i > Time.current.to_i && params[:state].is_a?(String) &&
          ActiveSupport::SecurityUtils.secure_compare(flow[:state].to_s, params[:state])
      end

      def failed_callback
        redirect_to member_integrations_github_path, alert: t("member.integrations.github.callback_failed")
      end

      def configured?
        Settings::Integrations.github_configured?
      end

      # No App on this install (self-hosted without GitHub, CYRA-916): no link, the page says why.
      def install_url
        return nil unless configured?

        slug = Settings::Integrations.value(:gh_app_slug) || "closeyourit"
        "https://github.com/apps/#{slug}/installations/new?#{URI.encode_www_form(state: start_flow)}"
      end

      def require_org_manage
        require_permission!("organization.manage")
      end
    end
  end
end
