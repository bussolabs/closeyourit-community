# frozen_string_literal: true

module Member
  module Product
    # Matrice funzionalità × piattaforme di un macro-progetto. Index = elenco dei prodotti
    # mappabili; show = la matrice del prodotto.
    #
    # Dentro Member::Product::* il costante `Product::Feature` risolverebbe a
    # Member::Product::Feature (NameError a runtime, non a boot): i model di dominio vanno SEMPRE
    # scritti fully-qualified con `::`. Stessa disciplina di Member::Knowledge::PagesController.
    class MatricesController < Member::BaseController
      before_action :require_view, only: %i[index show]
      before_action :set_group, only: :show

      def index
        # with_attached_icon_image: la lista rende l'EntityMark per prodotto → senza preload è un
        # active_storage_attachments per riga (stesso precedente di Member::GroupsController).
        # CYRA-684 — a pagine: i conteggi per riga si calcolano sui soli gruppi mostrati, il chip in
        # alto usa il totale della paginazione.
        @pagination = paginate(visible.groups.with_attached_icon_image.ordered)
        @groups = @pagination.records
        group_ids = @groups.map(&:id)
        @category_counts = ::Product::Category.where(group_id: group_ids).group(:group_id).count
        @feature_counts = ::Product::Feature.joins(:category)
                                            .where(product_categories: { group_id: group_ids })
                                            .group("product_categories.group_id").count
        # Copertura per piattaforma di ogni prodotto, aggregata in poche query (no N+1): l'elenco dice
        # "quanto è fatto e dove" senza aprire una matrice alla volta (CYRA-423).
        @coverage = ::Product::MatrixCoverage.for(group_ids: group_ids)
      end

      def show
        @categories = ::Product::Category.where(group_id: @group.id).ordered
                                         .includes(features: :knowledge_page).to_a
        @features = @categories.flat_map(&:features)
        @platforms = ::Product::MatrixColumns.for(group: @group)
        # Le celle si caricano in una query sola e si indicizzano per [funzionalità, piattaforma]:
        # la vista poi legge in memoria. Il preload di status/release/progetto è obbligatorio —
        # senza, ogni cella farebbe le sue query e Prosopite fa fallire la suite.
        @cells = ::Connections::FeaturePlatform
                 .where(feature_id: @features.map(&:id))
                 .includes(:status, release: :project)
                 .index_by { |cell| [ cell.feature_id, cell.platform_id ] }
        @missing_release_count = @cells.each_value.count(&:release_missing?)
      end

      private

      # Anti-BOLA: un prodotto non visibile (o di un'altra org) → RecordNotFound → 404, mai 403.
      # visible.groups e non Current.organization.groups: la matrice è contenuto
      # redazionale, chi non è assegnato al prodotto non deve vederne la mappa funzionalità.
      def set_group
        @group = visible.groups.with_attached_icon_image.find(params[:id])
      end

      def require_view
        require_permission!("product_features.view") unless can?("product_features.manage")
      end
    end
  end
end
