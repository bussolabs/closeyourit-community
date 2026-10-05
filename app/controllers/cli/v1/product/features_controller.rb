# frozen_string_literal: true

module Cli
  module V1
    module Product
      # Funzionalità della matrice (righe: "2FA", "Apple login") di un prodotto. La show porta con sé
      # le celle della funzionalità: da terminale è il modo per guardare una riga sola senza tirare
      # giù la matrice intera.
      #
      # La categoria arriva come `category` (UUID o nome) e si risolve SEMPRE dentro il prodotto del
      # path: una categoria inviata ma non riconosciuta è un errore, non un "lascia com'era" —
      # altrimenti spostare una funzionalità in una categoria di un altro prodotto sembrerebbe
      # riuscito mentre la funzionalità è rimasta dov'era.
      #
      # Model SEMPRE fully-qualified (`::Product::…`) — vedi BaseController.
      class FeaturesController < Cli::V1::Product::BaseController
        before_action :set_matrix_group!
        before_action :require_product_view, only: %i[index show]
        before_action :require_product_management, only: %i[create update destroy]
        before_action :set_feature, only: %i[show update destroy]

        def index
          records, meta = paginate(scoped_features)
          render_ok(FeatureSerializer.new(records), meta: meta)
        end

        def show
          cells = ::Connections::FeaturePlatform.where(feature_id: @feature.id)
                                                .includes(:status, :platform, release: :project).to_a
          render_ok(FeatureSerializer.new(@feature).as_json
                                     .merge("cells" => FeatureCellSerializer.new(cells).as_json))
        end

        def create
          category = find_category!(params[:category])
          result = save(category: category, attributes: feature_params)
          return render_result_error(result) if result.err?

          render_created(FeatureSerializer.new(result.value))
        end

        def update
          category = params.key?(:category) ? find_category!(params[:category]) : @feature.category
          result = save(category: category, attributes: partial_params(@feature), feature: @feature)
          return render_result_error(result) if result.err?

          render_ok(FeatureSerializer.new(result.value))
        end

        def destroy
          ::Product::Features::Destroy.call(feature: @feature)
          render_no_content
        end

        private

        def save(category:, attributes:, feature: nil)
          ::Product::Features::Save.call(category: category, actor: Current.account,
                                         organization: Current.organization,
                                         params: attributes, feature: feature)
        end

        # `category` filtra l'elenco (UUID o nome); assente = tutte le funzionalità del prodotto.
        # includes(:category): FeatureSerializer espone category_name → senza, una query per riga.
        def scoped_features
          scope = ::Product::Feature.joins(:category)
                                    .where(product_categories: { group_id: @group.id })
                                    .includes(:category)
                                    .order("product_categories.position", "product_categories.name",
                                           "product_features.position", "product_features.name")
          return scope unless params[:category].present?

          scope.where(category_id: find_category!(params[:category]).id)
        end

        def set_feature
          @feature = find_feature!(params[:id])
        end

        def feature_params
          params.permit(:name, :description, :position, :knowledge_page_id)
        end

        # Product::Features::Save è scritto per il form web, che rimanda SEMPRE ogni campo: quel che
        # non arriva lo riscrive a nil. Da terminale l'update è parziale (come `platforms update`),
        # quindi i campi non inviati si ripassano col valore attuale — altrimenti rinominare una
        # funzionalità ne cancellerebbe la descrizione senza che nessuno l'abbia chiesto.
        # knowledge_page_id resta fuori di proposito: il service lo tocca solo se la chiave è
        # presente, che è già la semantica dell'update parziale.
        def partial_params(feature)
          feature_params.reverse_merge(name: feature.name, description: feature.description,
                                       position: feature.position)
        end

        def render_result_error(result)
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end
    end
  end
end
