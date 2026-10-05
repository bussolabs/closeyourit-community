# frozen_string_literal: true

module Member
  module Monitoring
    module LogEntries
      # Collegamenti manuali log↔errore/ticket (oltre alla correlazione automatica per trace_id).
      # Gated dalla chiave RBAC scoped `logs.link` sul progetto del log; anti-BOLA via visible.logs.
      class LinksController < Member::BaseController
        before_action :set_entry
        before_action :require_link_permission

        def create
          linkable = resolve_linkable
          if linkable.nil?
            return redirect_to member_monitoring_log_entry_path(@entry),
                               alert: t("member.monitoring.logs.link_failed")
          end

          result = Logs::Links::Attach.call(log_entry: @entry, linkable: linkable, actor: Current.account)
          notice_or_alert(result)
        end

        def destroy
          link = @entry.links.find(params[:id])
          Logs::Links::Detach.call(log_entry: @entry, linkable: link.linkable)
          redirect_to member_monitoring_log_entry_path(@entry), notice: t("member.monitoring.logs.link_removed")
        end

        private

        # Anti-BOLA: log non visibile → RecordNotFound (404).
        def set_entry
          @entry = visible.logs.find(params[:log_entry_id])
        end

        def require_link_permission
          require_permission!("logs.link", scope: @entry.project)
        end

        # param "linkable" = "Errors::Group:<uuid>" | "Ticketing::Ticket:<uuid>". rpartition divide
        # sull'ULTIMO ":" (il type contiene "::"). Risolto NEL progetto del log (anti-BOLA) e solo per
        # i tipi ammessi; l'Attach valida comunque il confine di tenant.
        def resolve_linkable
          type, _, id = params[:linkable].to_s.rpartition(":")
          return nil unless Logs::Link::LINKABLE_TYPES.include?(type)

          type.constantize.where(project_id: @entry.project_id).find_by(id: id)
        end

        def notice_or_alert(result)
          if result.ok?
            redirect_to member_monitoring_log_entry_path(@entry), notice: t("member.monitoring.logs.link_created")
          else
            redirect_to member_monitoring_log_entry_path(@entry), alert: result.error.message
          end
        end
      end
    end
  end
end
