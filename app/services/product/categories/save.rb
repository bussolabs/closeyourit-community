# frozen_string_literal: true

module Product
  module Categories
    # Upsert di una categoria della matrice (crea se nuova, aggiorna se esistente). Il prodotto
    # (gruppo) e l'organizzazione non si toccano mai da fuori: arrivano dal gruppo risolto a monte
    # dentro lo scope visibile, così una categoria non può migrare in un altro tenant.
    class Save < ApplicationService
      def initialize(group:, actor:, params:, category: nil)
        @group = group
        @actor = actor
        @params = params
        @category = category || ::Product::Category.new
      end

      def call
        @category.assign_attributes(
          name: @params[:name],
          position: @params[:position].presence || @category.position || 0,
          group: @group,
          organization: @group.organization,
          created_by: @category.created_by || @actor
        )

        return Result.ok(@category) if @category.save

        Result.err(AppError.new(@category.errors.full_messages.to_sentence,
                                code: "R422-PRODUCT-001", details: @category.errors.to_hash))
      end
    end
  end
end
