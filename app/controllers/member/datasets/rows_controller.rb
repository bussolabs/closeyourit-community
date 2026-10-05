# frozen_string_literal: true

module Member
  module Datasets
    # Righe di dati di un dataset (valori scalari + celle foto). Lettura = visibilità del progetto;
    # scrittura gated datasets.manage sullo scope del dataset. Namespaced sotto Member::Datasets:: →
    # i model si referenziano SEMPRE fully-qualified ::Datasets::* (anti-shadowing).
    class RowsController < Member::BaseController
      before_action :set_dataset
      before_action :require_management
      before_action :set_row, only: %i[edit update destroy]

      def new
        @row = ::Datasets::Row.new(purpose: :sample)
        @columns = @dataset.columns.ordered.to_a
      end

      def create
        result = save_row
        if result.ok?
          redirect_to member_dataset_path(@dataset), notice: t("member.datasets.rows.created")
        else
          @row = ::Datasets::Row.new(purpose: :sample)
          rerender(result, :new)
        end
      end

      def edit
        @columns = @dataset.columns.ordered.to_a
      end

      def update
        result = save_row(@row)
        if result.ok?
          redirect_to member_dataset_path(@dataset), notice: t("member.datasets.rows.updated")
        else
          rerender(result, :edit)
        end
      end

      def destroy
        @row.destroy
        redirect_to member_dataset_path(@dataset), notice: t("member.datasets.rows.deleted")
      end

      private

      def save_row(row = nil)
        ::Datasets::Rows::Save.call(
          dataset: @dataset, actor: Current.account, row: row,
          values: params[:values]&.to_unsafe_h, photos: params[:photos]&.to_unsafe_h
        )
      end

      def rerender(result, action)
        @columns = @dataset.columns.ordered.to_a
        @errors = result.error.details || {}
        flash.now[:alert] = result.error.message
        render action, status: :unprocessable_content
      end

      # Anti-BOLA: dataset di un progetto non visibile → RecordNotFound (404).
      def set_dataset
        @dataset = visible.datasets.find(params[:dataset_id])
      end

      def set_row
        @row = @dataset.rows.find(params[:id])
      end

      def require_management
        require_permission!("datasets.manage", scope: @dataset.project)
      end
    end
  end
end
