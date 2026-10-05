# frozen_string_literal: true

module Cli
  module V1
    module Agents
      # Pin del bundle skill (singleton org): lettura dei 4 valori (repo/ref/version/digest) e upsert. Lettura
      # gated agents.view (manage-implies-view come la UI Member), scrittura agents.manage. Origine tipica
      # dell'update: la CI di `closeyourit-skills` al tag di release. Model SEMPRE ::Agents::* (anti-shadowing
      # sotto il namespace Agents del controller).
      class SkillBundlesController < Cli::V1::BaseController
        before_action :require_view,   only: :show
        before_action :require_manage, only: :update

        def show
          bundle = Current.organization.skill_bundle
          return render_error("R404-AGENT-004", "Nessuno skill bundle pinnato", status: :not_found) if bundle.nil?

          render_ok(serialize(bundle))
        end

        def update
          result = ::Agents::SkillBundles::Pin.call(
            organization: Current.organization,
            repo: params[:repo], ref: params[:ref], version: params[:version], digest: params[:digest],
            force: params[:force]
          )
          if result.ok?
            render_ok(serialize(result.value))
          else
            render_error(result.error.code, result.error.message, status: result.error.status, details: result.error.details)
          end
        end

        private

        def serialize(bundle)
          { repo: bundle.repo, ref: bundle.ref, version: bundle.version, digest: bundle.digest, updated_at: bundle.updated_at }
        end

        def require_view
          return true if authorization.can?("agents.view") || authorization.can?("agents.manage")

          render_error("R403-CLIAUTH-002", "Permesso negato", status: :forbidden)
          false
        end

        def require_manage
          require_permission!("agents.manage")
        end
      end
    end
  end
end
