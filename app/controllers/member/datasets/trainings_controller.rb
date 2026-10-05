# frozen_string_literal: true

module Member
  module Datasets
    # Training di un dataset (genera il prompt ottimizzato). Lettura = visibilità del progetto; lanciare
    # un training è gated `datasets.train` (costa chiamate LLM). Namespaced sotto Member::Datasets:: →
    # model sempre fully-qualified ::Datasets::*.
    class TrainingsController < Member::BaseController
      layout -> { turbo_frame_request? ? false : "member" }
      permission_not_required "Esito di un addestramento di un dataset visibile: sola lettura, il confine è la " \
                              "visibilità del progetto.",
                              only: %i[show]

      # La regola di avvio (righe minime, servizio collegato, mai due training insieme) sta nel service
      # condiviso col canale CLI; qui restano i testi della pagina, che sono quelli del sito e non
      # quelli di un'API. Il service parla per CODICE, la pagina traduce (CYRA-647).
      ALERTS = { "R422-DATASET-004" => "need_rows", "R409-DATASET-001" => "already_running" }.freeze

      before_action :set_dataset
      before_action :set_training, only: :show
      before_action :require_training_permission, only: :create

      def show; end

      def create
        result = ::Datasets::Trainings::Start.call(dataset: @dataset, actor: Current.account)
        return redirect_to(member_dataset_path(@dataset), alert: alert_for(result.error)) if result.err?

        redirect_to member_dataset_training_path(@dataset, result.value),
                    notice: t("member.datasets.trainings.started")
      end

      private

      def alert_for(error)
        key = ALERTS[error.code]
        key ? t("member.datasets.trainings.#{key}") : error.message
      end

      def set_dataset
        @dataset = visible.datasets.find(params[:dataset_id])
      end

      def set_training
        @training = @dataset.trainings.find(params[:id])
      end

      def require_training_permission
        require_permission!("datasets.train", scope: @dataset.project)
      end
    end
  end
end
