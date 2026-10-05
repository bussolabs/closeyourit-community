# frozen_string_literal: true

module Cli
  module V1
    module Projects
      # Collegamento host↔environment del progetto via CLI: POST collega, DELETE scollega. Gate
      # `uptime.manage` (scope progetto), come il canale Member (Member::ProjectServersController).
      # Distinto dal CLI org-level /cli/v1/servers (flotta): qui è il legame progetto↔host. Logica nei
      # service Servers::Links::{Attach,Detach} condivisi (`rules/backend-channels.md`). Anti-BOLA:
      # progetto in visible_projects; host org-scoped e attivo; environment tra quelli DICHIARATI dal
      # progetto; il link si risolve tra i server_links del progetto (id altrui → R404).
      class ServersController < Cli::V1::BaseController
        before_action :set_project!
        before_action -> { require_permission!("uptime.manage", scope: @project) }

        def create
          host = Current.organization.server_hosts.active.find_by(id: params[:host_id])
          environment = @project.environments.find_by(id: params[:environment_id])
          if host.nil? || environment.nil?
            return render_error("R422-SERVER-006", "Host o environment non collegabile",
                                status: :unprocessable_content)
          end

          result = ::Servers::Links::Attach.call(project: @project, environment: environment,
                                                 host: host, actor: Current.account)
          if result.ok?
            render_created(link_payload(result.value))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        def destroy
          link = @project.server_links.find(params[:id])
          ::Servers::Links::Detach.call(link: link)
          render_no_content
        end

        private

        def link_payload(link)
          { id: link.id, project_id: @project.id, environment_id: link.environment_id, host_id: link.host_id }
        end
      end
    end
  end
end
