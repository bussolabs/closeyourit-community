# frozen_string_literal: true

module Product
  # CYRA-423: copertura per piattaforma dei prodotti nell'ELENCO della matrice (livello 1). Per ogni
  # prodotto e piattaforma dice quante funzionalità sono ATTESE lì e quante già COPERTE, così l'elenco
  # risponde "quanto è fatto e dove" senza dover aprire una matrice alla volta.
  #
  # Attesa = la funzionalità dichiara quella piattaforma, cioè esiste una cella
  # (Connections::FeaturePlatform) con uno stato diverso da «non applicabile». Le piattaforme non
  # dichiarate — e quelle marcate «non applicabile» — NON entrano nel denominatore: decisione del
  # reporter, «meglio 12 su 12 che 12 su 18, così il numero dice la verità». Coperta = cella in uno
  # stato rilasciato (disponibile/in dismissione), la stessa nozione di Types::FeatureStatus#released?
  # con cui il resto della matrice conta ciò che è nelle mani degli utenti.
  #
  # Aggregato lato query e senza N+1: due conteggi raggruppati (attese, coperte) più una lettura delle
  # piattaforme coinvolte — tre query fisse a prescindere dal numero di prodotti (stesso vincolo di
  # Member::Product::MatricesController, dove Prosopite fa fallire la suite se le query crescono).
  class MatrixCoverage
    # Copertura di un prodotto su UNA piattaforma: `expected` è il denominatore (attese), `covered` il
    # numeratore (coperte).
    Row = Data.define(:platform, :expected, :covered) do
      def complete? = expected.positive? && covered == expected
    end

    def self.for(group_ids:)
      new(group_ids: group_ids).call
    end

    def initialize(group_ids:)
      @group_ids = Array(group_ids).uniq
    end

    def call
      return {} if @group_ids.empty?

      expected = count_by_group_and_platform(expected_cells)
      covered = count_by_group_and_platform(covered_cells)
      platforms = platforms_by_id(expected.keys.map(&:last).uniq)

      @group_ids.index_with do |group_id|
        platforms.filter_map do |platform_id, platform|
          count = expected[[ group_id, platform_id ]].to_i
          next if count.zero?

          Row.new(platform: platform, expected: count, covered: covered[[ group_id, platform_id ]].to_i)
        end
      end
    end

    private

    # Celle dei prodotti richiesti, unite allo stato (INNER: lo stato è obbligatorio) e alla categoria
    # per risalire al prodotto. Base comune ai due conteggi.
    def base
      ::Connections::FeaturePlatform
        .joins(:status, feature: :category)
        .where(product_categories: { group_id: @group_ids })
    end

    # Attese: ogni cella tranne «non applicabile». Valore intero dall'enum, senza affidarsi alla
    # traduzione dell'enum attraverso un merge su una join.
    def expected_cells
      base.where.not(types_feature_statuses: { category: not_applicable_value })
    end

    # Coperte: solo gli stati rilasciati (disponibile/in dismissione), come FeatureStatus#released?.
    def covered_cells
      base.where(types_feature_statuses: { category: released_values })
    end

    def count_by_group_and_platform(relation)
      relation.group("product_categories.group_id",
                     "#{::Connections::FeaturePlatform.table_name}.platform_id").count
    end

    def platforms_by_id(platform_ids)
      ::Types::Platform.where(id: platform_ids).ordered.index_by(&:id)
    end

    def not_applicable_value
      ::Types::FeatureStatus.categories.fetch("not_applicable")
    end

    def released_values
      ::Types::FeatureStatus.categories.values_at("available", "deprecated")
    end
  end
end
