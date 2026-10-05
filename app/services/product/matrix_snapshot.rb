# frozen_string_literal: true

module Product
  # Matrice completa di un prodotto in un payload solo: colonne (piattaforme), righe raggruppate per
  # categoria e celle. Query object senza mutazioni — nessun Result, come MatrixColumns.
  #
  # Esiste perché il canale CLI consegna la matrice in una risposta sola, mentre la vista web la
  # compone a pezzi nella pagina. Le celle restano una lista piatta e non annidate nella
  # funzionalità: chi legge da terminale le indicizza come vuole, e il payload non si gonfia di
  # incroci vuoti (la matrice è sparsa — la maggior parte delle caselle non è impostata).
  #
  # I preload sono obbligatori, non un'ottimizzazione: senza, ogni cella ricarica stato, release e
  # progetto e Prosopite fa fallire la suite (stesso motivo di Member::Product::MatricesController).
  class MatrixSnapshot
    def self.for(group:)
      new(group: group).call
    end

    def initialize(group:)
      @group = group
    end

    def call
      {
        product: { id: @group.id, name: @group.name, color: @group.color },
        platforms: PlatformSerializer.new(::Product::MatrixColumns.for(group: @group)).as_json,
        categories: categories.map { |category| serialize_category(category) },
        cells: FeatureCellSerializer.new(cells).as_json,
        missing_release_count: cells.count(&:release_missing?)
      }
    end

    private

    def categories
      @categories ||= ::Product::Category.where(group_id: @group.id).ordered
                                         .includes(features: :knowledge_page).to_a
    end

    def features
      @features ||= categories.flat_map(&:features)
    end

    def cells
      @cells ||= ::Connections::FeaturePlatform
                 .where(feature_id: features.map(&:id))
                 .includes(:status, :platform, release: :project)
                 .to_a
    end

    def serialize_category(category)
      FeatureCategorySerializer.new(category).as_json
                               .merge("features" => FeatureSerializer.new(category.features).as_json)
    end
  end
end
