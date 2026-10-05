# frozen_string_literal: true

module Cli
  module V1
    module Datasets
      # Previsioni di un dataset via CLI (CYRA-647): si chiede la previsione sui dati nuovi e se ne
      # legge il risultato. I dati in ingresso viaggiano con lo stesso contratto delle righe —
      # `values[<codice colonna>]` e `photos[<codice colonna>]` multipart — perché è esattamente
      # quello che sono: una riga del dataset, scritta per essere predetta invece che per insegnare.
      # La regola di avvio (serve un addestramento riuscito, serve il servizio collegato) sta nel
      # service condiviso ::Datasets::Predictions::Start, la stessa che usa la pagina.
      #
      # Chiedere = `datasets.train` sul progetto del dataset (costa una chiamata al servizio esterno);
      # leggere = visibilità del progetto. Anti-BOLA: il dataset si cerca fra i visibili (fuori scope →
      # R404 prima del gate) e la previsione dentro il dataset del path.
      #
      # Namespaced sotto Cli::V1::Datasets:: → i model si referenziano SEMPRE fully-qualified
      # ::Datasets::* (anti-shadowing).
      class PredictionsController < Cli::V1::BaseController
        include DatasetRowParams

        before_action :set_dataset
        before_action -> { require_permission!("datasets.train", scope: @dataset.project) }, only: :create
        before_action :set_prediction, only: :show

        def index
          records, meta = paginate(@dataset.predictions.ordered.includes(:created_by, input_row_association))
          render_ok(DatasetPredictionSerializer.new(records), meta: meta)
        end

        def show
          render_ok(DatasetPredictionSerializer.new(@prediction))
        end

        def create
          return unless shaped?

          result = ::Datasets::Predictions::Start.call(dataset: @dataset, actor: Current.account,
                                                       values: hash_param(:values), photos: hash_param(:photos))
          return render_start_error(result) if result.err?

          render_created(DatasetPredictionSerializer.new(result.value))
        end

        private

        def set_dataset
          @dataset = visible_datasets.includes(:project, :columns).find(params[:dataset_id])
        end

        def set_prediction
          @prediction = @dataset.predictions.includes(:created_by, input_row_association).find(params[:id])
        end

        def visible_datasets
          ::Datasets::Dataset.where(project_id: visible_projects.select(:id))
        end

        # La riga in ingresso viene serializzata con valori e metadati delle foto: senza precaricare
        # celle, colonne e blob ogni previsione dell'elenco farebbe le sue query (Prosopite le ferma).
        def input_row_association
          { input_row: { cells: [ :column, { image_attachment: :blob } ] } }
        end

        def render_start_error(result)
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end
    end
  end
end
