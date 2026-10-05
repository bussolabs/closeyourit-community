# frozen_string_literal: true

module Member
  module Monitoring
    # Stesso inventario della pagina flotta, ristretto a un host (tab "Database" del server) più la
    # pagina del singolo database. Thin come ServerActionsController — tabella, query object e
    # dettaglio sono servizi condivisi.
    class ServerDatabasesController < Member::BaseController
      # CYRA-737 — la base condivisa delle pagine-elenco dell'area di controllo.
      include Indexable

      # La crescita si guarda sui giorni: default 7d, non le 24h della pagina server.
      DEFAULT_RANGE = "7d"

      before_action :require_view
      before_action :set_host

      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :q, only: :index

      # The list now lives on the server's Disks & hardware tab; old links land there with their search.
      def index
        redirect_to member_monitoring_server_path(@host, tab: "hardware", **params.permit(:q, :sort, :page).to_h.symbolize_keys)
      end

      def show
        @name = params[:id].to_s
        @detail = ::Servers::DatabaseDetail.call(host: @host, name: @name,
                                                 hosts: visible.servers.with_database.ordered,
                                                 projects: visible.projects)
        # Un nome che su questa macchina non esiste è un 404, non una pagina vuota che sembra viva.
        raise ActiveRecord::RecordNotFound if @detail.blank?

        @range = range_param
        @buckets = ::Servers::Sample.database_size_buckets(host_id: @host.id, name: @name, range: @range)
        # Variazione nel periodo: dal primo al più recente valore osservato. Con un solo campione
        # (o nessuno) non c'è una crescita da dichiarare.
        observed = @buckets.filter_map { |bucket| bucket[:size_bytes] }
        @change_bytes = observed.size >= 2 ? observed.last - observed.first : nil
      end

      private

      def range_param
        value = params[:range].to_s
        ::Servers::Sample::RANGES.key?(value) ? value : DEFAULT_RANGE
      end

      # Anti-BOLA: host di un'altra organizzazione → RecordNotFound, come nelle altre pagine server.
      def set_host = @host = visible.servers.find(params[:server_id])

      def require_view
        return if can_view_servers?

        require_permission!("servers.view")
      end
    end
  end
end
