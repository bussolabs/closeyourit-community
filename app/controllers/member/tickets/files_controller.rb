# frozen_string_literal: true

module Member
  module Tickets
    # CYRA-1121 — apre un file del ticket o di un suo commento (anteprime, immagini, video, download).
    # È l'UNICA via per questi binari: le rotte generiche /rails/active_storage/ li rimandano qui
    # (RestrictedBlobServing), e le view non ne generano altre.
    #
    # Ogni richiesta ricontrolla che l'account veda ancora il ticket — anche ogni pezzo di un video:
    # niente redirect all'URL firmata dello storage, che resterebbe aperta per minuti a chiunque la
    # tenga. Il file passa dall'app, come i file della KB (Member::Knowledge::AttachmentsController).
    class FilesController < Member::BaseController
      permission_not_required "Aprire un file del ticket è baseline di chi vede il ticket: il confine è la " \
                              "visibilità, ricontrollata a ogni richiesta.",
                              only: %i[show]

      # Un'immagine o un pezzo di video non è una pagina aperta.
      skip_after_action :record_usage

      before_action :set_attachment

      def show
        blob = @attachment.blob
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Accept-Ranges"] = "bytes"
        # no-cache: il browser può tenere la copia, ma prima di riusarla torna qui (304 se invariata)
        # — e quindi ripassa dal controllo di visibilità. L'etag è solo quello del file: fresh_when ci
        # mescolerebbe flash, template e importmap, e la copia scaricata subito dopo il login (che ha
        # ancora il flash) non risulterebbe mai più invariata.
        response.strong_etag = blob.checksum || blob.key
        response.cache_control.merge!(no_cache: true, extras: [ "private" ])
        return head(:not_modified) if request.fresh?(response)

        ranges = Rack::Utils.get_byte_ranges(request.headers["Range"], blob.byte_size)
        # Nessun Range, o più di uno: il file intero (lo standard consente di ignorare il Range).
        return send_data(blob.download, **serving_options(blob)) if ranges.nil? || ranges.length > 1
        return send_unsatisfiable(blob) if ranges.empty?

        range = ranges.first
        response.headers["Content-Range"] = "bytes #{range.begin}-#{range.end}/#{blob.byte_size}"
        send_data blob.download_chunk(range), status: :partial_content, **serving_options(blob)
      rescue ActiveStorage::FileNotFoundError
        head :not_found
      end

      private

      # Anti-BOLA: ticket tra quelli visibili, file dentro quel ticket → altrimenti RecordNotFound,
      # mai 403 (come la KB).
      def set_attachment
        @ticket = visible.tickets.find(params[:ticket_id])
        @attachment = @ticket.find_file_attachment!(params[:id])
      end

      # Tipo e disposition seguono config/initializers/active_storage.rb: i tipi pericolosi escono come
      # binario, e solo raster/PDF/video possono essere mostrati inline — tutto il resto è scaricato.
      def serving_options(blob)
        requested = params[:disposition] == "attachment" ? :attachment : :inline
        { filename: blob.filename.sanitized, type: blob.content_type_for_serving,
          disposition: blob.forced_disposition_for_serving || requested }
      end

      def send_unsatisfiable(blob)
        response.headers["Content-Range"] = "bytes */#{blob.byte_size}"
        head :range_not_satisfiable
      end
    end
  end
end
