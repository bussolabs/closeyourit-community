# frozen_string_literal: true

module Cli
  module V1
    module Service
      module Accounts
        # Token CLI (cyi_u_) di un service account, da terminale. Gate members.manage. Il create ritorna
        # il SEGRETO una sola volta (reveal-once) accanto al record; in DB e nelle letture successive
        # esiste solo il prefix. destroy = revoca soft. Model SEMPRE ::Accounts::* fully-qualified.
        class TokensController < Cli::V1::BaseController
          before_action :require_manage
          before_action :set_account

          def index
            scope = @account.api_tokens.where(organization: Current.organization)
                            .order(revoked_at: :asc, created_at: :desc)
            records, meta = paginate(scope)
            render_ok(UserApiTokenSerializer.new(records), meta: meta)
          end

          def create
            # expires_at: nil ESPLICITO (CYRA-717): l'eccezione dei service account. Vedi il gemello
            # member — un'identità macchina non può rifare il device-flow ogni 90 giorni.
            result = ::Accounts::ApiTokens::Issue.call(
              account: @account, organization: Current.organization, name: params[:name], expires_at: nil
            )

            if result.ok?
              payload = UserApiTokenSerializer.new(result.value[:token]).as_json
              render json: { data: payload.merge("secret" => result.value[:secret]) }, status: :created
            else
              render_error(result.error.code, result.error.message,
                           status: result.error.status, details: result.error.details)
            end
          end

          def destroy
            token = @account.api_tokens.where(organization: Current.organization).find(params[:id])
            ::Accounts::ApiTokens::Revoke.call(token: token)
            render_no_content
          end

          private

          def set_account
            @account = Current.organization.accounts.service.find(params[:account_id])
          end

          def require_manage
            require_permission!("members.manage")
          end
        end
      end
    end
  end
end
