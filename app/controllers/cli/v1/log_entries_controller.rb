# frozen_string_literal: true

module Cli
  module V1
    # Stream di log cross-app (token utente). Scope = log dei progetti VISIBILI (gate via visibilità,
    # nessuna chiave d'azione di lettura). Filtro opzionale project_id risolto dentro lo scope visibile
    # (fuori scope → R404, anti-BOLA). Paginazione offset. show risolve il singolo log nello scope
    # visibile (log di un progetto non visibile → R404); i collegamenti manuali stanno in log_entries/links.
    class LogEntriesController < Cli::V1::BaseController
      def index
        # CYRA-738 — ordine e filtri li mette Logs::Entries::Query, la stessa del canale API.
        records, meta = paginate(::Logs::Entries::Query.call(
                                   scope: scoped_logs, level: params[:level],
                                   trace_id: params[:trace_id], environment: params[:environment]
                                 ))
        render_ok(LogEntrySerializer.new(records), meta: meta)
      end

      def show
        entry = Logs::Entry.where(project_id: visible_projects.select(:id)).find(params[:id])
        render_ok(LogEntrySerializer.new(entry))
      end

      private

      def scoped_logs
        return Logs::Entry.where(project_id: visible_projects.select(:id)) if params[:project_id].blank?

        Logs::Entry.where(project: visible_projects.find(params[:project_id]))
      end
    end
  end
end
