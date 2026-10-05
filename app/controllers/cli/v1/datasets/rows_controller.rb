# frozen_string_literal: true

module Cli
  module V1
    module Datasets
      # Righe di un dataset via CLI (CYRA-646): valori scalari + foto, con lo stesso contratto del
      # form del sito — `values[<codice colonna>]` per i valori, `photos[<codice colonna>]` multipart
      # per le immagini. La logica sta nel service condiviso ::Datasets::Rows::Save (obbligatori,
      # sniff del tipo sui byte reali, tutto o niente), qui solo auth, gate e serializzazione.
      #
      # Lettura (elenco, scarico di una foto) = visibilità del progetto; aggiungere, modificare ed
      # eliminare = `datasets.manage` sul progetto del dataset. Anti-BOLA: il dataset si cerca fra i
      # visibili (fuori scope → R404 prima del gate) e la riga dentro il dataset del path.
      #
      # Namespaced sotto Cli::V1::Datasets:: → i model si referenziano SEMPRE fully-qualified
      # ::Datasets::* (anti-shadowing).
      class RowsController < Cli::V1::BaseController
        include DatasetRowParams

        before_action :set_dataset
        before_action -> { require_permission!("datasets.manage", scope: @dataset.project) },
                      only: %i[create update destroy]
        before_action :set_row, only: %i[update destroy photo]

        # Di default le righe di ESEMPIO, quelle che si vedono nella scheda del dataset sul sito.
        # `?purpose=prediction` mostra gli input di inferenza, `?purpose=all` entrambi: sono due cose
        # diverse mischiate nella stessa tabella, e chi conta gli esempi non deve trovarci dentro le
        # domande fatte al modello.
        def index
          scope = @dataset.rows.ordered.includes(cells: [ :column, { image_attachment: :blob } ])
          scope = scope.where(purpose: purpose_filter) if purpose_filter
          records, meta = paginate(scope)
          render_ok(DatasetRowSerializer.new(records), meta: meta)
        end

        def create
          return unless shaped?

          result = save_row
          return render_row_error(result) unless result.ok?

          render_created(DatasetRowSerializer.new(result.value))
        end

        # Modifica PARZIALE, per i valori come per le foto: quello che non nomini resta dov'è. Il
        # canale web manda sempre tutta la riga perché ce l'ha sotto gli occhi; da terminale
        # cambiare un solo valore non deve svuotare gli altri — e quelli obbligatori li farebbe
        # pure fallire, con un rifiuto che il chiamante non saprebbe spiegarsi.
        def update
          return unless shaped?

          result = save_row(@row)
          return render_row_error(result) unless result.ok?

          render_ok(DatasetRowSerializer.new(@row.reload))
        end

        def destroy
          @row.destroy
          render_no_content
        end

        # Consegna il binario di una cella foto. Come per gli allegati e i documenti: tipo neutro e
        # disposition attachment, così nemmeno un client che apra la risposta in un browser possa
        # vedersela renderizzare.
        def photo
          cell = @row.cells.joins(:column).find_by(datasets_columns: { code: params[:code].to_s })
          return head :not_found if cell.nil? || !cell.image.attached?

          response.headers["X-Content-Type-Options"] = "nosniff"
          send_data cell.image.download,
                    filename: cell.image.blob.filename.to_s,
                    type: "application/octet-stream",
                    disposition: "attachment"
        end

        private

        def set_dataset
          @dataset = visible_datasets.includes(:project, :columns).find(params[:dataset_id])
        end

        def set_row
          @row = @dataset.rows.includes(cells: :column).find(params[:id])
        end

        def visible_datasets
          ::Datasets::Dataset.where(project_id: visible_projects.select(:id))
        end

        def save_row(row = nil)
          ::Datasets::Rows::Save.call(dataset: @dataset, actor: Current.account, row: row,
                                      values: merged_values(row), photos: photos_param)
        end

        # Su una riga esistente si parte dai valori che ha già: la richiesta li aggiorna, non li
        # sostituisce in blocco.
        def merged_values(row)
          sent = hash_param(:values)
          return sent if row.nil?

          (row.cell_values || {}).merge(sent)
        end

        def photos_param = hash_param(:photos)

        # nil = nessun filtro (`?purpose=all`); altrimenti l'elenco dei purpose richiesti, con
        # "sample" come default quando il parametro manca o non dice niente di valido.
        def purpose_filter
          return @purpose_filter if defined?(@purpose_filter)

          raw = Array(params[:purpose]).map { |value| value.to_s.strip }.reject(&:blank?)
          @purpose_filter =
            if raw.include?("all")
              nil
            else
              (raw & ::Datasets::Row.purposes.keys).presence || [ "sample" ]
            end
        end

        def render_row_error(result)
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end
    end
  end
end
