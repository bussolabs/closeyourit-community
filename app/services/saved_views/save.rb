# frozen_string_literal: true

module SavedViews
  # Crea o aggiorna (upsert per nome, nella stessa risorsa) una vista salvata dell'account nell'org
  # corrente. Estrae solo le chiavi-filtro ammesse per la risorsa; il model sanifica e scarta i vuoti.
  # Result pattern.
  class Save < ApplicationService
    def initialize(account:, organization:, resource_type:, name:, params:)
      @account = account
      @organization = organization
      @resource_type = resource_type.to_s
      @name = name.to_s.strip
      @params = params || {}
    end

    def call
      view = SavedView.for(account: @account, organization: @organization)
                      .for_resource(@resource_type)
                      .find_or_initialize_by(name: @name)
      view.resource_type = @resource_type
      view.filters = extracted_filters(view)
      return Result.ok(view) if view.save

      Result.err(AppError.new(I18n.t("shared.saved_views.errors.invalid"),
                              code: "R422-SAVEDVIEW-001", details: view.errors.to_hash))
    end

    private

    def extracted_filters(view)
      view.allowed_filter_keys.index_with { |key| @params[key] }
    end
  end
end
