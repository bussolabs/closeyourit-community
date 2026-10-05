# frozen_string_literal: true

module Product
  module Categories
    # Elimina una categoria della matrice, ma solo se è vuota. Il DB cascaderebbe volentieri su
    # funzionalità e celle: un click di troppo cancellerebbe in silenzio mesi di lavoro redazionale,
    # quindi qui si chiede di svuotarla prima.
    class Destroy < ApplicationService
      def initialize(category:)
        @category = category
      end

      def call
        if @category.features.exists?
          return Result.err(AppError.new(I18n.t("member.product.categories.errors.not_empty"),
                                         code: "R422-PRODUCT-004"))
        end

        @category.destroy
        Result.ok(@category)
      end
    end
  end
end
