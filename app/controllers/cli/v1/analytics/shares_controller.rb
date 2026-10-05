# frozen_string_literal: true

module Cli
  module V1
    module Analytics
      # Link pubblico di condivisione (embed) della dashboard analytics di un progetto, sub-resource
      # SINGLETON: create genera il link (password opzionale), destroy revoca quello attivo.
      # CYRA-697 — gated `analytics.share.manage` come il canale web: una falla aperta da un lato solo
      # resta una falla. Anti-BOLA + parità web: il progetto si risolve tra i visibili E
      # analytics-collecting (come Member::Monitoring::Analytics::SharesController) → non si genera un link
      # pubblico su un progetto che non raccoglie analytics. Logica nei service Analytics::Links::{Create,Revoke}.
      class SharesController < Cli::V1::BaseController
        before_action :set_project
        before_action -> { require_permission!("analytics.share.manage", scope: @project) }

        def create
          result = ::Analytics::Links::Create.call(project: @project, password: params[:password].presence,
                                                   actor: Current.account)
          if result.ok?
            render_created(share_payload(result.value))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        def destroy
          link = @project.analytics_links.active.first
          ::Analytics::Links::Revoke.call(link: link) if link
          render_no_content
        end

        private

        def set_project
          @project = visible_projects.analytics_collecting.find(params[:project_id])
        end

        def share_payload(link)
          { id: link.id, slug: link.slug, active: link.enabled }
        end
      end
    end
  end
end
