# frozen_string_literal: true

module Member
  module Product
    # Categorie della matrice (le righe-gruppo: "Auth", "Notifiche"). Non hanno una pagina propria:
    # si creano e si modificano dalla matrice del prodotto, dove vivono.
    #
    # Model SEMPRE fully-qualified (::Product::Category): dentro Member::Product:: il costante
    # `Product::Category` risolverebbe a Member::Product::Category → NameError a runtime.
    class CategoriesController < Member::BaseController
      before_action :require_management
      before_action :set_category, only: %i[edit update destroy]
      before_action :set_group, only: %i[new create]

      def new
        @category = ::Product::Category.new(group: @group)
      end

      def create
        result = ::Product::Categories::Save.call(group: @group, actor: Current.account, params: category_params)
        if result.ok?
          redirect_to member_product_matrix_path(@group), notice: t("member.product.categories.created")
        else
          @category = ::Product::Category.new(group: @group, name: category_params[:name])
          @errors = result.error.details
          flash.now[:alert] = result.error.message
          render :new, status: :unprocessable_content
        end
      end

      def edit; end

      def update
        result = ::Product::Categories::Save.call(group: @category.group, actor: Current.account,
                                                  params: category_params, category: @category)
        if result.ok?
          redirect_to member_product_matrix_path(@category.group), notice: t("member.product.categories.updated")
        else
          @errors = result.error.details
          flash.now[:alert] = result.error.message
          render :edit, status: :unprocessable_content
        end
      end

      def destroy
        group = @category.group
        result = ::Product::Categories::Destroy.call(category: @category)
        if result.ok?
          redirect_to member_product_matrix_path(group), notice: t("member.product.categories.deleted")
        else
          redirect_to member_product_matrix_path(group), alert: result.error.message
        end
      end

      private

      # Anti-BOLA: la categoria si cerca SEMPRE dentro i prodotti visibili → 404, mai 403.
      def set_category
        @category = ::Product::Category.where(group_id: visible.groups.select(:id)).find(params[:id])
      end

      def set_group
        @group = visible.groups.find(params[:matrix_id])
      end

      def category_params
        params.permit(:name, :position)
      end

      def require_management
        require_permission!("product_features.manage")
      end
    end
  end
end
