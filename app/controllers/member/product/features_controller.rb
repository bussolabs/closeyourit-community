# frozen_string_literal: true

module Member
  module Product
    # Funzionalità della matrice (le righe: "2FA", "Apple login"). La categoria si sceglie nel form;
    # arrivando da "nuova funzionalità" di una categoria, quella è già preselezionata.
    #
    # Model SEMPRE fully-qualified (::Product::Feature) — vedi CategoriesController.
    class FeaturesController < Member::BaseController
      # Quante pagine della base di conoscenza proporre nel form (la tendina è ricercabile, ma un
      # elenco illimitato appesantirebbe la pagina). Quella già collegata è sempre inclusa a parte.
      PAGES_LIMIT = 200

      before_action :require_management
      before_action :set_feature, only: %i[edit update destroy]
      before_action :set_group_and_categories
      before_action :set_pages, only: %i[new create edit update]

      def new
        @feature = ::Product::Feature.new(category: @categories.first)
      end

      def create
        category = resolve_category
        return category_not_found if category.nil?

        result = save(category: category)
        if result.ok?
          redirect_to member_product_matrix_path(@group), notice: t("member.product.features.created")
        else
          @feature = ::Product::Feature.new(category: category, name: feature_params[:name],
                                            description: feature_params[:description])
          @errors = result.error.details
          flash.now[:alert] = result.error.message
          render :new, status: :unprocessable_content
        end
      end

      def edit; end

      def update
        # Una categoria inviata ma non riconosciuta è un errore, non un "lascia com'era": senza
        # questo, spostare una funzionalità in una categoria di un altro prodotto sembrerebbe
        # riuscito e la funzionalità resterebbe dov'era. Assente = update parziale, si tiene la sua.
        category = resolve_category(fallback: @feature.category)
        return category_not_found if category.nil?

        result = save(category: category, feature: @feature)
        if result.ok?
          redirect_to member_product_matrix_path(@group), notice: t("member.product.features.updated")
        else
          @errors = result.error.details
          flash.now[:alert] = result.error.message
          render :edit, status: :unprocessable_content
        end
      end

      def destroy
        ::Product::Features::Destroy.call(feature: @feature)
        redirect_to member_product_matrix_path(@group), notice: t("member.product.features.deleted")
      end

      private

      # La categoria si cerca SOLO fra quelle del prodotto (anti-BOLA per costruzione). Il fallback
      # vale unicamente quando il campo non è stato inviato.
      def resolve_category(fallback: nil)
        return fallback unless params.key?(:category_id)

        @categories.find { |candidate| candidate.id == params[:category_id] }
      end

      def category_not_found
        redirect_to member_product_matrix_path(@group),
                    alert: t("member.product.features.errors.category_not_found")
      end

      def save(category:, feature: nil)
        ::Product::Features::Save.call(category: category, actor: Current.account,
                                       organization: Current.organization,
                                       params: feature_params, feature: feature)
      end

      # Anti-BOLA: la funzionalità si cerca dentro i prodotti visibili → 404, mai 403.
      def set_feature
        @feature = ::Product::Feature.joins(:category)
                                     .where(product_categories: { group_id: visible.groups.select(:id) })
                                     .find(params[:id])
      end

      # Il prodotto arriva dalla funzionalità (edit/update/destroy), dalla categoria di partenza
      # (nuova funzionalità da una riga-categoria) o dal parametro della matrice.
      def set_group_and_categories
        @group = resolve_group
        @categories = ::Product::Category.where(group_id: @group.id).ordered.to_a
      end

      # Pagine KB collegabili: solo quelle visibili all'account (anti-BOLA lato affordance; il
      # service ricontrolla comunque l'id inviato). Solo per i form — la destroy non ne ha bisogno.
      #
      # La pagina già collegata resta sempre in elenco anche se il limite la taglierebbe fuori:
      # altrimenti la tendina rimanderebbe "nessuna" e un salvataggio qualsiasi scollegherebbe la
      # pagina senza che nessuno l'abbia chiesto.
      def set_pages
        @pages = ::Knowledge::Page.visible_to(account: Current.account, organization: Current.organization)
                                  .order(:title).limit(PAGES_LIMIT).to_a
        current = @feature&.knowledge_page
        @pages.unshift(current) if current && @pages.none? { |page| page.id == current.id }
      end

      def resolve_group
        return @feature.category.group if @feature

        if params[:category_id].present?
          category = ::Product::Category.where(group_id: visible.groups.select(:id))
                                        .find_by(id: params[:category_id])
          return category.group if category
        end

        visible.groups.find(params[:matrix_id])
      end

      def feature_params
        params.permit(:name, :description, :position, :knowledge_page_id)
      end

      def require_management
        require_permission!("product_features.manage")
      end
    end
  end
end
