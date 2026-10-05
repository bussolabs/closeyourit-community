# frozen_string_literal: true

module Cli
  module V1
    module Agents
      # Token org dell'automator (cyi_a_) via CLI: lista + creazione con reveal-once del segreto + revoca
      # soft. Tutto gated da agents.manage. Il create ritorna il SEGRETO una sola volta accanto al record;
      # in DB e nelle letture successive esiste solo il prefix. Mirror di Cli::V1::ServerTokensController.
      # Model SEMPRE ::Agents::* fully-qualified (anti-shadowing: qui "Agents" è Cli::V1::Agents).
      class TokensController < Cli::V1::BaseController
        before_action :require_manage

        def index
          records, meta = paginate(Current.organization.agent_tokens
                                                        .order(revoked_at: :asc, created_at: :desc))
          render_ok(AgentTokenSerializer.new(records), meta: meta)
        end

        def create
          result = ::Agents::Tokens::Issue.call(
            organization: Current.organization, name: params[:name], created_by: Current.account
          )
          if result.ok?
            payload = AgentTokenSerializer.new(result.value[:token]).as_json
            render json: { data: payload.merge("secret" => result.value[:secret]) }, status: :created
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        def destroy
          token = Current.organization.agent_tokens.find(params[:id])
          ::Agents::Tokens::Revoke.call(token: token)
          render_no_content
        end

        private

        def require_manage
          require_permission!("agents.manage")
        end
      end
    end
  end
end
