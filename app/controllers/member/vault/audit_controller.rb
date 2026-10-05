# frozen_string_literal: true

module Member
  module Vault
    # Pagina Audit del Vault (CYRA-135): elenco navigabile e filtrabile degli eventi sui secret org-scoped
    # (variabili di progetto, variabili shared, file). Gated dal permesso org-level secrets_audit.view.
    # Gli eventi personali (per-utente) restano fuori: sono privati dell'utente, non audit dell'org.
    class AuditController < Member::BaseController
      before_action :require_audit_view

      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :event_action, :q, only: :index

      def index
        query = Secrets::AuditQuery.new(
          organization: Current.organization,
          visible_project_ids: visible.projects.pluck(:id),
          filters: audit_filters,
          oldest_first: current_sort == [ "occurred_at", :asc ]
        )
        @pagination = paginate_rows(query.rows)
        @events = @pagination.records
        @projects = visible.projects.index_by(&:id)
        @environments = Current.organization.environments.index_by(&:id)
        @saved_views = saved_views_for("secret_events")
      end

      private

      def require_audit_view
        require_permission!("secrets_audit.view")
      end

      # `action` e riservato (nome dell'azione controller) → il filtro azione viaggia come `event_action`.
      def audit_filters
        {
          action: params[:event_action].presence,
          environment_id: params[:environment_id].presence,
          actor_id: params[:actor_id].presence,
          from: time_bound(:from),
          to: time_bound(:to),
          q: search_q.presence
        }
      end

      # Le righe uniscono 3 tabelle (nessuna relation) → paginazione offset sull'array, restituendo un
      # Pagination::Result compatibile con Ui::PaginationComponent.
      def paginate_rows(rows, per: Pagination::DEFAULT_PER)
        total = rows.size
        total_pages = total.zero? ? 1 : (total.to_f / per).ceil
        page = params[:page].to_i
        page = 1 if page < 1
        page = total_pages if page > total_pages
        Pagination::Result.new(records: Array(rows.slice((page - 1) * per, per)),
                               page: page, per: per, total: total, total_pages: total_pages)
      end
    end
  end
end
