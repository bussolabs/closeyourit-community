# frozen_string_literal: true

module Cli
  module V1
    module Datasets
      # Addestramenti di un dataset via CLI (CYRA-647): si avvia l'addestramento e se ne segue lo stato
      # fino al risultato, senza aprire il sito. La regola di avvio (righe di esempio a sufficienza,
      # servizio collegato, mai due addestramenti insieme sullo stesso dataset) sta tutta nel service
      # condiviso ::Datasets::Trainings::Start — la stessa che usa la pagina.
      #
      # Avviare = `datasets.train` sul progetto del dataset (costa chiamate al servizio esterno);
      # leggere = visibilità del progetto, come sul sito. Anti-BOLA: il dataset si cerca fra i visibili
      # (fuori scope → R404 prima del gate, mai 403) e l'addestramento dentro il dataset del path.
      #
      # Namespaced sotto Cli::V1::Datasets:: → i model si referenziano SEMPRE fully-qualified
      # ::Datasets::* (anti-shadowing).
      class TrainingsController < Cli::V1::BaseController
        before_action :set_dataset
        before_action -> { require_permission!("datasets.train", scope: @dataset.project) }, only: :create
        before_action :set_training, only: :show

        def index
          records, meta = paginate(@dataset.trainings.ordered.includes(:created_by))
          render_ok(DatasetTrainingSerializer.new(records), meta: meta)
        end

        def show
          render_ok(DatasetTrainingSerializer.new(@training))
        end

        def create
          result = ::Datasets::Trainings::Start.call(dataset: @dataset, actor: Current.account)
          return render_start_error(result) if result.err?

          render_created(DatasetTrainingSerializer.new(result.value))
        end

        private

        def set_dataset
          @dataset = visible_datasets.includes(:project).find(params[:dataset_id])
        end

        def set_training
          @training = @dataset.trainings.includes(:created_by).find(params[:id])
        end

        def visible_datasets
          ::Datasets::Dataset.where(project_id: visible_projects.select(:id))
        end

        def render_start_error(result)
          render_error(result.error.code, result.error.message, status: result.error.status)
        end
      end
    end
  end
end
