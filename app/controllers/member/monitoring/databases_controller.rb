# frozen_string_literal: true

module Member
  module Monitoring
    # Inventario database di TUTTA la flotta: una riga per database trovato dall'agent su un host
    # visibile. Sola lettura — i dati arrivano dal push dell'agent, qui non si muta nulla e l'app
    # non si connette mai ai database monitorati. Classe flat nel modulo Monitoring (MAI un modulo
    # Member::Monitoring::Databases: ombreggerebbe le costanti di dominio).
    class DatabasesController < Member::BaseController
      # CYRA-737 — la base condivisa delle pagine-elenco dell'area di controllo.
      include Indexable

      before_action :require_view

      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :server, :q, only: :index

      def index
        # visible.servers = scope org + RBAC: un host di un'altra organizzazione non esiste.
        @hosts = visible.servers.with_database.ordered
        scope = @hosts
        scope = scope.where(id: params[:server]) if params[:server].present?

        rows = ::Servers::DatabaseInventory.call(hosts: scope, q: search_q, sort: params[:sort], changes: true)
        @rows = paginated_rows(rows, per: ::Servers::Constants::DATABASES_PER_PAGE)
        @total_bytes = rows.sum { |row| row.size_bytes.to_i }
        # F105 — the sizes are each agent's last push: the oldest one says how old the page can be.
        @data_from = scope.minimum(:last_seen_at)
      end

      private

      def require_view
        return if can_view_servers?

        require_permission!("servers.view")
      end
    end
  end
end
