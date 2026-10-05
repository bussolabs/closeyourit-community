# frozen_string_literal: true

module Member
  module Service
    module Accounts
      # Token CLI (cyi_u_) di un service account: conio con reveal-once + revoca. Gated members.manage.
      # I service account non fanno il device-flow (niente browser) → l'owner conia il token qui e lo
      # copia UNA volta. Il segreto è reso inline nella show (mai in sessione). Model SEMPRE ::Accounts::*.
      class TokensController < Member::BaseController
        before_action :require_manage
        before_action :set_account

        def create
          # expires_at: nil ESPLICITO (CYRA-717): un token personale scade da solo dopo 90 giorni,
          # ma qui l'identità è una macchina, senza browser per rifare il device-flow — una scadenza
          # fermerebbe l'automazione ogni tre mesi senza che nessuno se ne accorga prima del guasto.
          result = ::Accounts::ApiTokens::Issue.call(
            account: @account, organization: current_organization, name: params[:name], expires_at: nil
          )

          if result.ok?
            @revealed = result.value   # { token:, secret: } — mostrato UNA sola volta
            load_account_detail
            render "member/service/accounts/show", status: :created
          else
            @errors = result.error.details.presence || { base: [ result.error.message ] }
            load_account_detail
            render "member/service/accounts/show", status: :unprocessable_content
          end
        end

        def destroy
          token = @account.api_tokens.where(organization: current_organization).find(params[:id])
          ::Accounts::ApiTokens::Revoke.call(token: token)
          redirect_to member_service_account_path(@account), notice: t("member.service_accounts.tokens.revoked")
        end

        private

        # Anti-BOLA: token solo per un service account dell'org corrente.
        def set_account
          @account = current_organization.accounts.service.find(params[:account_id])
        end

        def load_account_detail
          @membership = current_organization.memberships.find_by(account: @account)
          @secret_environment_codes = @membership&.secret_environment_codes || []
          @grantable_environments = current_organization.environments.order(:code).to_a
          @tokens = @account.api_tokens.where(organization: current_organization)
                            .order(revoked_at: :asc, created_at: :desc)
          @visible_projects = @account.directly_accessible_projects.where(organization: current_organization).order(:name)
          @roles = @account.assigned_roles.where(organization: current_organization).order(:name)
          @grants = @account.account_permissions.where(organization: current_organization).order(:permission_key)
        end

        def require_manage
          require_permission!("members.manage")
        end
      end
    end
  end
end
