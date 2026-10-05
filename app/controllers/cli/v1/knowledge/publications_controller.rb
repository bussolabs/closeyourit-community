# frozen_string_literal: true

module Cli
  module V1
    module Knowledge
      # PUT project-scoped di una pubblicazione Knowledge idempotente. `knowledge.edit` è richiesto
      # anche sul create perché il contratto può adottare e aggiornare una pagina legacy altrui.
      class PublicationsController < Cli::V1::BaseController
        before_action :set_publication_project
        before_action :require_publication_permission

        def update
          result = ::Knowledge::Pages::Publish.call(
            project: @project,
            actor: Current.account,
            publication_key: params[:publication_key],
            params: publication_params
          )
          return render_publish(result.value) if result.ok?

          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end

        private

        def set_publication_project
          @project = visible_projects.find(params[:project_id])
        rescue ActiveRecord::RecordNotFound
          render_error(
            "R404-KNOWLEDGE-001",
            I18n.t("member.knowledge.errors.project_not_found"),
            status: :not_found
          )
        end

        def require_publication_permission
          require_permission!("knowledge.edit", scope: @project)
        end

        def publication_params
          params.permit(:title, :body, :kind, tags: [])
        end

        def render_publish(outcome)
          # Anti-leak: il token è scoped → serializza solo i progetti/gruppi visibili al publisher
          # (una publish convergente può collegare la pagina a progetti che non vede).
          payload = {
            data: KnowledgePageSerializer.new(outcome.page, params: visible_scope_params).as_json,
            meta: { operation: outcome.operation, adopted_legacy: outcome.adopted_legacy }
          }
          render json: payload, status: outcome.operation == "created" ? :created : :ok
        end

        def visible_scope_params
          {
            visible_project_ids: visible_projects.pluck(:id).to_set,
            visible_group_ids: visible_groups.pluck(:id).to_set
          }
        end
      end
    end
  end
end
