# frozen_string_literal: true

module Member
  module Datasets
    # Inferenza: applica il prompt ottimizzato dell'ultimo training a una foto/riga nuova, predicendo i
    # target. Gated `datasets.train` (costa una chiamata LLM). Namespaced → model ::Datasets::* fully-qualified.
    class PredictionsController < Member::BaseController
      layout -> { modal_form_request? ? "member_modal" : (turbo_frame_request? ? false : "member") }
      permission_not_required "Esito di una predizione di un dataset visibile: sola lettura, il confine è la " \
                              "visibilità del progetto.",
                              only: %i[show]

      before_action :set_dataset
      before_action :require_training_permission, only: %i[new create]
      before_action :set_prediction, only: :show

      def new
        @input_columns = @dataset.input_columns
        @training = latest_training
        redirect_to member_dataset_path(@dataset), alert: t("member.datasets.predictions.need_training") if @training.nil?
      end

      # La regola di avvio (serve un training completato, serve il servizio collegato, la riga in
      # ingresso si scrive col service delle righe) sta nel service condiviso col canale CLI (CYRA-647).
      # Qui resta la resa: i campi in errore tornano nel form, il resto è un avviso sulla scheda.
      def create
        result = ::Datasets::Predictions::Start.call(dataset: @dataset, actor: Current.account,
                                                     values: params[:values]&.to_unsafe_h,
                                                     photos: params[:photos]&.to_unsafe_h)
        return handle_error(result.error) if result.err?

        redirect_to member_dataset_prediction_path(@dataset, result.value),
                    notice: t("member.datasets.predictions.started")
      end

      def show
        unless turbo_frame_request?
          @input_row = @prediction.input_row
          @input_columns = @dataset.input_columns
        end
        @target_columns = @dataset.target_columns
      end

      private

      def latest_training
        @dataset.trainings.status_done.ordered.first
      end

      def handle_error(error)
        return rerender(error) if error.code == "R422-DATASET-003"

        alert = error.code == "R422-DATASET-005" ? t("member.datasets.predictions.need_training") : error.message
        redirect_to member_dataset_path(@dataset), alert: alert
      end

      def rerender(error)
        @input_columns = @dataset.input_columns
        @training = latest_training
        @errors = error.details || {}
        flash.now[:alert] = error.message
        render :new, status: :unprocessable_content
      end

      def set_dataset
        @dataset = visible.datasets.find(params[:dataset_id])
      end

      def set_prediction
        @prediction = @dataset.predictions.find(params[:id])
      end

      def require_training_permission
        require_permission!("datasets.train", scope: @dataset.project)
      end
    end
  end
end
