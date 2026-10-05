# frozen_string_literal: true

module Product
  module Features
    # Upsert di una funzionalità (riga della matrice). La categoria arriva già risolta dentro lo
    # scope visibile; la pagina della base di conoscenza si risolve QUI dentro le pagine visibili
    # all'autore: un id di una pagina che non può vedere non viene trovato e la richiesta cade,
    # invece di creare un rimando a contenuto altrui (anti-BOLA per costruzione).
    class Save < ApplicationService
      def initialize(category:, actor:, organization:, params:, feature: nil)
        @category = category
        @actor = actor
        @organization = organization
        @params = params
        @feature = feature || ::Product::Feature.new
      end

      def call
        page = resolve_knowledge_page
        return @page_error if @page_error

        @feature.assign_attributes(
          name: @params[:name],
          description: @params[:description],
          position: @params[:position].presence || @feature.position || 0,
          category: @category,
          organization: @category.organization,
          created_by: @feature.created_by || @actor
        )
        # Solo se il campo è stato inviato: un update parziale non deve azzerare il rimando alla KB.
        @feature.knowledge_page = page if @params.key?(:knowledge_page_id)

        return Result.ok(@feature) if @feature.save

        Result.err(AppError.new(@feature.errors.full_messages.to_sentence,
                                code: "R422-PRODUCT-002", details: @feature.errors.to_hash))
      end

      private

      def resolve_knowledge_page
        return nil unless @params.key?(:knowledge_page_id)

        page_id = @params[:knowledge_page_id].presence
        return nil if page_id.nil?

        page = visible_pages.find_by(id: page_id)
        if page.nil?
          @page_error = Result.err(AppError.new(I18n.t("member.product.features.errors.page_not_found"),
                                                code: "R422-PRODUCT-002"))
        end
        page
      end

      def visible_pages
        ::Knowledge::Page.visible_to(account: @actor, organization: @organization)
      end
    end
  end
end
