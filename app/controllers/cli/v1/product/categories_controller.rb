# frozen_string_literal: true

module Cli
  module V1
    module Product
      # Categorie della matrice (righe-gruppo: "Auth", "Notifiche") di un prodotto. Il prodotto e
      # l'organizzazione non arrivano mai dal client: li mette il service partendo dal gruppo del
      # path, già risolto dentro lo scope visibile.
      #
      # `set_matrix_group!` gira PRIMA del gate di scrittura: su un prodotto che non posso vedere la
      # risposta è 404, non 403 (un 403 confermerebbe che quel prodotto esiste).
      #
      # Model SEMPRE fully-qualified (`::Product::…`) — vedi BaseController.
      class CategoriesController < Cli::V1::Product::BaseController
        before_action :set_matrix_group!
        before_action :require_product_view, only: :index
        before_action :require_product_management, only: %i[create update destroy]
        before_action :set_category, only: %i[update destroy]

        def index
          records, meta = paginate(::Product::Category.where(group_id: @group.id).ordered)
          render_ok(FeatureCategorySerializer.new(records), meta: meta)
        end

        def create
          result = ::Product::Categories::Save.call(group: @group, actor: Current.account, params: category_params)
          return render_result_error(result) if result.err?

          render_created(FeatureCategorySerializer.new(result.value))
        end

        def update
          result = ::Product::Categories::Save.call(group: @group, actor: Current.account,
                                                    params: partial_params(@category), category: @category)
          return render_result_error(result) if result.err?

          render_ok(FeatureCategorySerializer.new(result.value))
        end

        def destroy
          result = ::Product::Categories::Destroy.call(category: @category)
          return render_result_error(result) if result.err?

          render_no_content
        end

        private

        def set_category
          @category = find_category!(params[:id])
        end

        def category_params
          params.permit(:name, :position)
        end

        # Product::Categories::Save è scritto per il form web, che rimanda SEMPRE ogni campo: quel
        # che non arriva lo riscrive. Da terminale l'update è parziale (come `platforms update` o
        # `kb update`), quindi i campi non inviati si ripassano col valore attuale — altrimenti
        # cambiare la sola posizione svuoterebbe il nome e la richiesta morirebbe su una validazione.
        def partial_params(category)
          category_params.reverse_merge(name: category.name, position: category.position)
        end

        def render_result_error(result)
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end
    end
  end
end
