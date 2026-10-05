# frozen_string_literal: true

module Member
  module Agents
    # Token org dell'automator (cyi_a_): lista + creazione con reveal-once del segreto + revoca. Gated
    # agents.manage. Pattern Member::Monitoring::ServerTokensController. Model SEMPRE ::Agents::* (anti-shadowing).
    class TokensController < Member::BaseController
      SORT_COLUMNS = {
        "name" => "LOWER(agents_tokens.name)",
        "prefix" => :token_prefix,
        "last_used" => :last_used_at,
        "status" => :revoked_at
      }.freeze

      before_action :require_manage

      def index
        load_tokens
      end

      def create
        result = ::Agents::Tokens::Issue.call(
          organization: Current.organization,
          name: params[:name],
          created_by: Current.account
        )

        if result.ok?
          # Reveal-once: il segreto è mostrato UNA sola volta, qui, senza finire in DB né in sessione.
          @revealed = result.value
          load_tokens
          render :index, status: :created
        else
          @errors = result.error.details.presence || { base: [ result.error.message ] }
          load_tokens
          render :index, status: :unprocessable_content
        end
      end

      def destroy
        token = Current.organization.agent_tokens.find(params[:id])
        ::Agents::Tokens::Revoke.call(token: token)
        redirect_to member_agents_tokens_path, notice: t("member.agents.tokens.revoked")
      end

      private

      def load_tokens
        tokens = Current.organization.agent_tokens
        @total_count = tokens.count
        @active_count = tokens.active.count
        scope = tokens.order(revoked_at: :asc, created_at: :desc)
        @pagination = paginate(sorted(scope, columns: SORT_COLUMNS))
        @tokens = @pagination.records
      end

      def require_manage
        require_permission!("agents.manage")
      end
    end
  end
end
